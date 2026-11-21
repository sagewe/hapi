import Foundation
import SwiftUI
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Markdown image resolution policy (mirrors web/src/lib/markdown-file-assets.ts)

public enum MarkdownImageTarget: Equatable, Sendable {
    case remote(URL)
    case local(path: String, mimeType: String)
    case inert
}

public enum MarkdownImagePolicy {
    public static let maxImageBytes = 10 * 1024 * 1024

    private static let imageMimeByExtension: [String: String] = [
        "apng": "image/apng",
        "avif": "image/avif",
        "bmp": "image/bmp",
        "gif": "image/gif",
        "heic": "image/heic",
        "heif": "image/heif",
        "ico": "image/x-icon",
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "png": "image/png",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "webp": "image/webp",
    ]

    public static func imageMimeType(for path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = normalized.split(separator: "/").last.map(String.init) ?? normalized
        guard let dot = lastComponent.lastIndex(of: "."), lastComponent.index(after: dot) < lastComponent.endIndex else {
            return nil
        }
        let ext = String(lastComponent[lastComponent.index(after: dot)...]).lowercased()
        return imageMimeByExtension[ext]
    }

    private static func stripHrefMeta(_ value: String) -> String {
        let hashIndex = value.firstIndex(of: "#")
        let queryIndex = value.firstIndex(of: "?")
        let cut: String.Index?
        switch (hashIndex, queryIndex) {
        case let (h?, q?): cut = min(h, q)
        case let (h?, nil): cut = h
        case let (nil, q?): cut = q
        default: cut = nil
        }
        return cut.map { String(value[..<$0]) } ?? value
    }

    private static func isWindowsAbsolutePath(_ value: String) -> Bool {
        MarkdownTransforms.isWindowsAbsolutePath(value)
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") || isWindowsAbsolutePath(value)
    }

    private static func resolveLexicalPath(_ raw: String) -> String? {
        let norm = raw.replacingOccurrences(of: "\\", with: "/")
        let absolute = norm.hasPrefix("/")
        let isDrive = isWindowsAbsolutePath(norm)
        let parts = norm.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for (idx, part) in parts.enumerated() {
            if part.isEmpty || part == "." { continue }
            if isDrive && idx == 0 {
                out.append(part)
                continue
            }
            if part == ".." {
                if out.isEmpty { return nil }
                if isDrive && out.count == 1 { return nil }
                out.removeLast()
                continue
            }
            out.append(part)
        }
        if absolute { return "/" + out.joined(separator: "/") }
        if isDrive {
            guard let drive = out.first else { return nil }
            let rest = out.dropFirst()
            return rest.isEmpty ? "\(drive)/" : "\(drive)/" + rest.joined(separator: "/")
        }
        return out.joined(separator: "/")
    }

    private static func inferHomeDir(workspacePath: String) -> String? {
        if workspacePath == "/root" || workspacePath.hasPrefix("/root/") {
            return "/root"
        }
        let parts = workspacePath.split(separator: "/", omittingEmptySubsequences: true)
        if workspacePath.hasPrefix("/"), parts.count >= 2, parts[0] == "Users" || parts[0] == "home" {
            return "/\(parts[0])/\(parts[1])"
        }
        return nil
    }

    private static func expandTildePath(_ path: String, workspacePath: String?) -> String? {
        guard path == "~" || path.hasPrefix("~/"), let workspacePath, let home = inferHomeDir(workspacePath: workspacePath) else {
            return nil
        }
        if path == "~" { return home }
        let rest = String(path.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        return "\(home)/\(rest)"
    }

    public static func isWithinWorkspace(_ absPath: String, workspacePath: String) -> Bool {
        guard let target = resolveLexicalPath(absPath),
              let root = resolveLexicalPath(workspacePath) else { return false }
        let normTarget = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normRoot = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullTarget = target.hasPrefix("/") ? "/\(normTarget)" : normTarget
        let fullRoot = root.hasPrefix("/") ? "/\(normRoot)" : normRoot
        let windows = isWindowsAbsolutePath(fullTarget) && isWindowsAbsolutePath(fullRoot)
        let comparableTarget = windows ? fullTarget.lowercased() : fullTarget
        let comparableRoot = windows ? fullRoot.lowercased() : fullRoot
        return comparableTarget == comparableRoot || comparableTarget.hasPrefix("\(comparableRoot)/")
    }

    private static func normalizeLocalPath(currentFilePath: String, target: String) -> String? {
        let current = currentFilePath.replacingOccurrences(of: "\\", with: "/")
        let rawTarget = target.replacingOccurrences(of: "\\", with: "/")
        if isAbsolutePath(rawTarget) {
            return resolveLexicalPath(rawTarget)
        }
        let dirParts = current.split(separator: "/", omittingEmptySubsequences: true).dropLast().map(String.init)
        let combined = (dirParts + rawTarget.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
            .joined(separator: "/")
        let resolved = resolveLexicalPath(current.hasPrefix("/") ? "/\(combined)" : combined)
        guard let resolved, !resolved.isEmpty else { return nil }
        return resolved
    }

    /// Resolve a markdown image destination into a safe remote URL, a
    /// workspace-bounded local path, or `.inert`.
    public static func resolve(
        destination: String,
        currentFilePath: String? = nil,
        workspacePath: String? = nil
    ) -> MarkdownImageTarget {
        let raw = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .inert }
        if raw.hasPrefix("#") || raw.hasPrefix("?") { return .inert }

        if raw.hasPrefix("//") {
            let candidate = "https:" + raw
            guard let url = InlineBuilder.makeURL(from: candidate),
                  url.host != nil else { return .inert }
            return .remote(url)
        }

        if raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("http://") {
            guard HrefPolicy.classify(raw) != .blocked,
                  let url = InlineBuilder.makeURL(from: raw),
                  url.host != nil else { return .inert }
            return .remote(url)
        }

        if raw.lowercased().hasPrefix("file://") {
            guard let workspacePath, !workspacePath.isEmpty,
                  let url = URL(string: stripHrefMeta(raw)), url.isFileURL else {
                return .inert
            }
            let filePath = url.path
            guard isWithinWorkspace(filePath, workspacePath: workspacePath),
                  let resolved = resolveLexicalPath(filePath),
                  let mime = imageMimeType(for: resolved) else {
                return .inert
            }
            return .local(path: resolved, mimeType: mime)
        }

        if HrefPolicy.hasScheme(raw) && !isWindowsAbsolutePath(raw) {
            return .inert
        }

        let stripped = stripHrefMeta(raw)
        let decoded = stripped.removingPercentEncoding ?? stripped
        guard !decoded.isEmpty else { return .inert }

        let candidate: String
        if decoded == "~" || decoded.hasPrefix("~/") {
            guard let expanded = expandTildePath(decoded, workspacePath: workspacePath) else {
                return .inert
            }
            candidate = expanded
        } else {
            candidate = decoded
        }

        let effectiveCurrent = currentFilePath ?? ".hapi-chat-message.md"
        if isAbsolutePath(candidate) {
            guard let workspacePath, !workspacePath.isEmpty,
                  isWithinWorkspace(candidate, workspacePath: workspacePath) else {
                return .inert
            }
        }
        if isAbsolutePath(effectiveCurrent) && (workspacePath == nil || workspacePath?.isEmpty == true) {
            return .inert
        }

        guard let normalized = normalizeLocalPath(currentFilePath: effectiveCurrent, target: candidate) else {
            return .inert
        }
        if let workspacePath, !workspacePath.isEmpty, isAbsolutePath(normalized),
           !isWithinWorkspace(normalized, workspacePath: workspacePath) {
            return .inert
        }
        guard let mime = imageMimeType(for: normalized) else {
            return .inert
        }
        return .local(path: normalized, mimeType: mime)
    }
}

// MARK: - Environment-injected image loader

/// Loads markdown images (workspace-relative/absolute files via Hub API or
/// remote `http(s)` URLs) with in-memory caching and off-main downsampling.
@MainActor
public final class HapiMarkdownImageLoader {
    public typealias LocalFetch = @Sendable (_ path: String, _ maxBytes: Int) async throws -> Data
    public typealias RemoteFetch = @Sendable (_ url: URL, _ maxBytes: Int) async throws -> Data

    private let workspacePathProvider: @MainActor () -> String?
    public let currentFilePath: String?
    private let fetchLocal: LocalFetch
    private let fetchRemote: RemoteFetch
    private let rawCache = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    #if canImport(UIKit)
    private let thumbnailCache = NSCache<NSString, UIImage>()
    #endif

    public var workspacePath: String? {
        workspacePathProvider()
    }

    public convenience init(
        workspacePath: String? = nil,
        currentFilePath: String? = nil,
        fetchLocal: @escaping LocalFetch,
        fetchRemote: @escaping RemoteFetch = HapiMarkdownImageLoader.defaultRemoteFetch
    ) {
        self.init(
            workspacePathProvider: { workspacePath },
            currentFilePath: currentFilePath,
            fetchLocal: fetchLocal,
            fetchRemote: fetchRemote
        )
    }

    public init(
        workspacePathProvider: @escaping @MainActor () -> String?,
        currentFilePath: String? = nil,
        fetchLocal: @escaping LocalFetch,
        fetchRemote: @escaping RemoteFetch = HapiMarkdownImageLoader.defaultRemoteFetch
    ) {
        self.workspacePathProvider = workspacePathProvider
        self.currentFilePath = currentFilePath
        self.fetchLocal = fetchLocal
        self.fetchRemote = fetchRemote
        rawCache.countLimit = 24
        rawCache.totalCostLimit = 32 * 1024 * 1024
        #if canImport(UIKit)
        thumbnailCache.countLimit = 40
        thumbnailCache.totalCostLimit = 16 * 1024 * 1024
        #endif
    }

    public func resolveTarget(for destination: String) -> MarkdownImageTarget {
        MarkdownImagePolicy.resolve(
            destination: destination,
            currentFilePath: currentFilePath,
            workspacePath: workspacePath
        )
    }

    public func clearCache() {
        rawCache.removeAllObjects()
        #if canImport(UIKit)
        thumbnailCache.removeAllObjects()
        #endif
    }

    public func loadData(for target: MarkdownImageTarget) async throws -> Data {
        let key: String
        switch target {
        case .local(let path, _):
            key = "local:\(path)"
        case .remote(let url):
            key = "remote:\(url.absoluteString)"
        case .inert:
            throw CocoaError(.fileNoSuchFile)
        }

        if let cached = rawCache.object(forKey: key as NSString) {
            return cached as Data
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let fetchLocal = self.fetchLocal
        let fetchRemote = self.fetchRemote
        let maxBytes = MarkdownImagePolicy.maxImageBytes
        let task = Task<Data, Error> {
            let data: Data
            switch target {
            case .local(let path, _):
                data = try await fetchLocal(path, maxBytes)
            case .remote(let url):
                data = try await fetchRemote(url, maxBytes)
            case .inert:
                throw CocoaError(.fileNoSuchFile)
            }
            guard !data.isEmpty, data.count <= maxBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        rawCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    #if canImport(UIKit)
    public func cachedThumbnail(for target: MarkdownImageTarget) -> UIImage? {
        guard let key = cacheKey(for: target) else { return nil }
        return thumbnailCache.object(forKey: key as NSString)
    }

    public func loadThumbnail(for target: MarkdownImageTarget) async throws -> UIImage {
        guard let key = cacheKey(for: target) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let cached = thumbnailCache.object(forKey: key as NSString) {
            return cached
        }
        let data = try await loadData(for: target)
        let image: UIImage = try await Task.detached(priority: .utility) {
            try Self.decodeThumbnail(from: data, maxPixelSize: 1280)
        }.value
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        thumbnailCache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    public func loadOriginalImage(for target: MarkdownImageTarget) async throws -> UIImage {
        let data = try await loadData(for: target)
        return try await Task.detached(priority: .utility) {
            guard let image = UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return image
        }.value
    }

    private nonisolated static func decodeThumbnail(from data: Data, maxPixelSize: Int) throws -> UIImage {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
           ] as CFDictionary) {
            return UIImage(cgImage: thumbnail)
        }
        guard let fallback = UIImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return fallback
    }
    #endif

    private func cacheKey(for target: MarkdownImageTarget) -> String? {
        switch target {
        case .local(let path, _): return "local:\(path)"
        case .remote(let url): return "remote:\(url.absoluteString)"
        case .inert: return nil
        }
    }

    public nonisolated static func defaultRemoteFetch(_ url: URL, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty, data.count <= maxBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        return data
    }
}

private struct HapiMarkdownImageLoaderKey: EnvironmentKey {
    static let defaultValue: HapiMarkdownImageLoader? = nil
}

public extension EnvironmentValues {
    /// Loader for inline markdown images in chat and file previews.
    /// Defaults to nil so isolated tests/previews fall back to placeholder rows.
    var hapiMarkdownImageLoader: HapiMarkdownImageLoader? {
        get { self[HapiMarkdownImageLoaderKey.self] }
        set { self[HapiMarkdownImageLoaderKey.self] = newValue }
    }
}

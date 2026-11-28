import Foundation
import HapiClient
import Observation
import PDFKit
import UIKit

@Observable @MainActor
final class CaseFilesModel {
    let api: APIClient
    let sessionId: String
    private(set) var files: [CaseFile] = []
    var activeZip: ZIPRoute?
    var error: String?
    var busy = false

    private var cache: [String: GeneratedMediaFile] = [:]
    private var pdfThumbCache: [String: UIImage] = [:]

    init(api: APIClient, sessionId: String) {
        self.api = api
        self.sessionId = sessionId
    }

    /// All deliverable PDFs ranked as report candidates (newest first).
    var reportCandidates: [CaseFile] {
        let pdfs = files.filter { !$0.isUpload && $0.isPDF }
        let named = pdfs.filter { file in
            ["报告", "尽调", "report", "纪要", "核查"].contains {
                file.fileName.localizedCaseInsensitiveContains($0)
            }
        }
        let pool = named.isEmpty ? pdfs : named
        return pool.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    /// Latest primary report PDF.
    var report: CaseFile? {
        reportCandidates.first
    }

    /// Earlier report drafts folded under the latest primary report.
    var previousReports: [CaseFile] {
        Array(reportCandidates.dropFirst())
    }

    func refresh() async {
        do {
            files = try await api.caseFiles(sessionId: sessionId)
            error = nil
        } catch {
            if !Task.isCancelled {
                self.error = "资料暂时无法读取，请重试"
            }
        }
    }

    func local(_ file: CaseFile) async throws -> GeneratedMediaFile {
        if let cached = cache[file.selectionID] { return cached }
        let diskURL = Self.diskCacheURL(sessionId: sessionId, fileId: file.id, fileName: file.fileName)
        if let existing = try? Data(contentsOf: diskURL), !existing.isEmpty {
            let local = try await Task.detached(priority: .utility) {
                try GeneratedMediaFile(data: existing, fileName: file.fileName, mimeType: file.mimeType)
            }.value
            cache[file.selectionID] = local
            return local
        }
        let data = try await api.caseFileBytes(sessionId: sessionId, file: file)
        Task.detached(priority: .background) {
            Self.writeDiskCache(data: data, url: diskURL)
        }
        let local = try await Task.detached(priority: .utility) {
            try GeneratedMediaFile(data: data, fileName: file.fileName, mimeType: file.mimeType)
        }.value
        cache[file.selectionID] = local
        return local
    }

    func pdfCoverThumbnail(for file: CaseFile) async -> UIImage? {
        guard file.isPDF else { return nil }
        if let cached = pdfThumbCache[file.selectionID] { return cached }
        guard let local = try? await local(file) else { return nil }
        let url = local.url
        let rendered: UIImage? = await Task.detached(priority: .utility) {
            Self.renderPDFCover(url: url, targetSize: CGSize(width: 120, height: 160))
        }.value
        if let rendered {
            pdfThumbCache[file.selectionID] = rendered
        }
        return rendered
    }

    func openZip(mediaId: String) async {
        if files.isEmpty { await refresh() }
        guard let target = files.first(where: { $0.id == mediaId && $0.isZIP })
            ?? files.first(where: { $0.isZIP }) else { return }
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let localFile = try await local(target)
            let archive = try await Task.detached {
                try SafeZIP(data: Data(contentsOf: localFile.url))
            }.value
            activeZip = ZIPRoute(file: localFile, archive: archive)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sharing(_ files: [CaseFile], title: String) async throws -> [GeneratedMediaFile] {
        var locals: [GeneratedMediaFile] = []
        for file in files { locals.append(try await local(file)) }
        guard locals.count > 1, !files.allSatisfy(\.isImage) else { return locals }
        return [try await Self.package(locals, title: title)]
    }

    static func package(_ files: [GeneratedMediaFile], title: String) async throws -> GeneratedMediaFile {
        guard files.reduce(0, { $0 + $1.byteCount }) <= SafeZIP.maxTotalBytes else { throw SafeZIPError.tooLarge }
        return try await Task.detached(priority: .utility) {
            let bytes = try SafeZIP.pack(files.map { (name: $0.url.lastPathComponent, data: try Data(contentsOf: $0.url)) })
            let name = String(title.prefix(30)).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            return try GeneratedMediaFile(data: bytes, fileName: "\(name.isEmpty ? "本案" : name)_精选资料(\(files.count)份).zip", mimeType: "application/zip")
        }.value
    }

    nonisolated static func renderPDFCover(url: URL, targetSize: CGSize) -> UIImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        return page.thumbnail(of: targetSize, for: .mediaBox)
    }

    nonisolated static func diskCacheURL(sessionId: String, fileId: String, fileName: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safeSession = sanitizeSegment(sessionId)
        let safeId = sanitizeSegment(fileId)
        let safeName = sanitizeFilename(fileName)
        return caches
            .appendingPathComponent("qiqi-case-files", isDirectory: true)
            .appendingPathComponent(safeSession, isDirectory: true)
            .appendingPathComponent(safeId, isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: false)
    }

    nonisolated static func writeDiskCache(data: Data, url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        pruneCacheIfNeeded(maxBytes: 150 * 1024 * 1024)
    }

    nonisolated private static func pruneCacheIfNeeded(maxBytes: Int64) {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let root = caches.appendingPathComponent("qiqi-case-files", isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            let sz = Int64(vals.fileSize ?? 0)
            total += sz
            entries.append((url, sz, vals.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for item in entries {
            if total <= maxBytes * 3 / 4 { break }
            try? fm.removeItem(at: item.url)
            total -= item.size
        }
    }

    nonisolated private static func sanitizeSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? "item" : String(str.prefix(80))
    }

    nonisolated private static func sanitizeFilename(_ value: String) -> String {
        let base = (value as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        return cleaned.isEmpty ? "file.bin" : cleaned
    }
}

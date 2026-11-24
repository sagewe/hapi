import Foundation
import HapiClient
import Observation

@Observable @MainActor
final class CaseFilesModel {
    let api: APIClient
    let sessionId: String
    private(set) var files: [CaseFile] = []
    var report: CaseFile? {
        let pdfs = files.filter { !$0.isUpload && $0.isPDF }
        return pdfs.filter { file in
            ["报告", "尽调", "report"].contains { file.fileName.localizedCaseInsensitiveContains($0) }
        }.max(by: { $0.createdAt < $1.createdAt }) ?? pdfs.first
    }
    var error: String?
    var busy = false
    private var cache: [String: GeneratedMediaFile] = [:]
    init(api: APIClient, sessionId: String) { self.api = api; self.sessionId = sessionId }
    func refresh() async {
        do { files = try await api.caseFiles(sessionId: sessionId); error = nil }
        catch { if !Task.isCancelled { self.error = "资料暂时无法读取，请重试" } }
    }
    func local(_ file: CaseFile) async throws -> GeneratedMediaFile {
        if let cached = cache[file.selectionID] { return cached }
        let data = try await api.caseFileBytes(sessionId: sessionId, file: file)
        let local = try await Task.detached(priority: .utility) {
            try GeneratedMediaFile(data: data, fileName: file.fileName, mimeType: file.mimeType)
        }.value
        cache[file.selectionID] = local
        return local
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
}

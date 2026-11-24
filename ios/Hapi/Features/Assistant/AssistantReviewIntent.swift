import AppIntents
import HapiClient
import Observation
import UniformTypeIdentifiers

/// Foreground handoff, shared by Open In and Shortcuts. It only stages local
/// drafts; choosing a case and pressing Send remain explicit user actions.
@Observable @MainActor
final class AssistantFileInbox {
    static let shared = AssistantFileInbox()
    private var files: [PreparedAttachment] = []
    private(set) var revision = 0
    func receive(_ files: [PreparedAttachment]) { self.files.append(contentsOf: files); revision += 1 }
    func drain() -> [PreparedAttachment] { defer { files = [] }; return files }
}

struct AssistantReviewDocumentsIntent: AppIntent {
    static let title: LocalizedStringResource = "送审文件"
    static let description = IntentDescription("将 ZIP、PDF、Office 或图片送到合规工作台，确认新建调查或补传当前案。")
    static let openAppWhenRun = true
    @Parameter(title: "资料") var files: [IntentFile]
    func perform() async throws -> some IntentResult {
        guard files.count <= 20 else { throw ImportError.tooMany }
        var prepared: [PreparedAttachment] = []
        for file in files {
            let result: PrepareResult
            if let url = file.fileURL { result = await AttachmentPreparer.prepare(fileURL: url) }
            else { result = await AttachmentPreparer.prepare(data: file.data, filename: file.filename, mimeType: file.type?.preferredMIMEType ?? "application/octet-stream") }
            guard case .ready(let attachment) = result else { throw ImportError.unreadable }
            prepared.append(attachment)
        }
        await AssistantFileInbox.shared.receive(prepared)
        return .result()
    }
    enum ImportError: LocalizedError {
        case tooMany, unreadable
        var errorDescription: String? { self == .tooMany ? "请每次送审不超过 20 份资料" : "文件无法读取或超过 50 MB，请重新选择" }
    }
}
struct AssistantReviewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AssistantReviewDocumentsIntent(), phrases: ["用\(.applicationName)送审文件"], shortTitle: "送审文件", systemImageName: "doc.badge.arrow.up")
    }
}

import Foundation
import AppIntents
import HapiClient
@testable import HapiProtocol
import HapiUI
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor final class CaseFilesTests: XCTestCase {
    private struct HTTP: HTTPPerforming {
        let files: [CaseFile]
        let pdf: Data; let png: Data; let zip: Data
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!, path = url.path
            var bytes = Data("{}".utf8), mime = "application/json"
            if path.hasSuffix("case-files") { bytes = try JSONEncoder().encode(["files": files]) }
            else if path.contains("/generated-images/") || path.contains("/uploads/") {
                if path.hasSuffix("archive") { bytes = zip; mime = "application/zip" }
                else if path.contains("shot") { bytes = png; mime = "image/png" }
                else { bytes = pdf; mime = "application/pdf" }
            } else if path.hasSuffix("hub-settings") { bytes = Data(#"{"clientProfile":{"mode":"assistant","defaultAgent":"agy","defaultDirectory":"/test","modelPresets":[{"id":"quick","label":"快速","model":"test-quick","effort":"medium"},{"id":"deep","label":"深度","model":"test-deep","effort":"high","isDefault":true}],"quickActions":[{"id":"company","title":"企业主体与股权穿透","prompt":"核查企业"},{"id":"individual","title":"自然人核查","prompt":"核查自然人"},{"id":"document","title":"单据审核","prompt":"审核单据"},{"id":"sanctions","title":"制裁与高风险筛查","prompt":"筛查制裁"}]}}"#.utf8) }
            else if path.hasSuffix("/sessions") { var summary = await HomeFilterTestData.summary("case81", machine: "test"); summary.metadata?.name = "示例贸易公司 · 单据与股权尽调"; summary.metadata?.flavor = "agy"; bytes = try JSONEncoder().encode(SessionsResponse(sessions: [summary])) }
            else if path.hasSuffix("/upload") { bytes = Data(#"{"success":true,"path":"/test/contract.docx"}"#.utf8) }
            else if path.hasSuffix("-models") { bytes = Data(#"{"success":true,"models":[],"availableModels":[]}"#.utf8) }
            else if path.hasSuffix("/messages") {
                let rows = [DecryptedMessage(id: "summary", seq: 1, content: ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": "结论摘要\n\n已核对商业发票、提单与登记摘录。示例贸易公司主体一致，未发现单据间金额与币种冲突。实控人资料仍需补充确认。"]]], createdAt: 1000, invokedAt: 1000),
                    DecryptedMessage(id: "report", seq: 2, content: ["role": "agent", "content": ["type": "codex", "data": ["type": "generated-image", "imageId": "report", "fileName": "示例贸易公司_合规尽调报告.pdf", "mimeType": "application/pdf"]]], createdAt: 2000, invokedAt: 2000)]
                bytes = try JSONEncoder().encode(MessagesResponse(messages: rows, page: MessagesPage(direction: .latest, limit: 200, epoch: 1, reset: false, snapshotHeadSeq: 2, snapshotHeadAt: 2000, hasMore: false)))
            } else if path.contains("voice") { bytes = Data(#"{"providers":[]}"#.utf8) }
            return (bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!)
        }
    }
    private func setup() async throws -> (HubSession, CaseFilesModel, Data) {
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { context in
            context.beginPage(); ("示例贸易公司 · 合规尽调报告\n\n结论：原件主体与单据金额一致。" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 240)).image { context in
            UIColor.systemBlue.withAlphaComponent(0.1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
            ("官方登记 · 核验摘录\n示例主体登记一致\n合成验收资料" as NSString).draw(at: CGPoint(x: 24, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.systemBlue])
        }
        let png = try XCTUnwrap(image.pngData())
        let zip = try SafeZIP.pack([(name: "Commercial_Invoice_2026.pdf", data: pdf), (name: "Bill_of_Lading_BL9921.pdf", data: pdf), (name: "Sales_Contract_Final.docx", data: Data("test".utf8)), (name: "Packing_List_Detail.xlsx", data: Data("test".utf8)), (name: "Buyer_License_Scan.jpg", data: png)])
        var files: [CaseFile] = []
        func add(_ id: String, _ name: String, _ mime: String, upload: Bool = false, size: Int) {
            files.append(CaseFile(id: id, category: upload ? "uploads" : "deliverables", fileName: name, mimeType: mime, size: size, createdAt: 1795487400000))
        }
        add("report", "示例贸易公司_合规尽调报告.pdf", "application/pdf", size: pdf.count)
        add("official", "税务局_官方登记摘录.pdf", "application/pdf", size: pdf.count)
        for n in 1...3 { add("shot\(n)", "官方核验图\(n).png", "image/png", size: png.count) }
        add("archive", "全套贸易单据.zip", "application/zip", upload: true, size: zip.count)
        add("original", "MT103水单.pdf", "application/pdf", upload: true, size: pdf.count)
        files.swapAt(0, 1)
        let http = HTTP(files: files, pdf: pdf, png: png, zip: zip)
        let store = InMemoryCredentialStore(), url = "http://casefiles-\(UUID()).invalid".lowercased()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try store.store(HubCredentials(hubUrl: url, accessToken: "test", jwt: "e30.\(payload).test"))
        let session = try XCTUnwrap(HubSession(hubUrl: url, credentialStore: store, performer: http))
        await session.refreshClientProfile(); try await session.sessionStore.refresh()
        let model = CaseFilesModel(api: session.api, sessionId: "case81"); await model.refresh()
        return (session, model, zip)
    }
    func testShortcutStagesFilesForExplicitDestinationConfirmation() async throws {
        _ = AssistantFileInbox.shared.drain()
        let (session, _, zip) = try await setup(); defer { session.shutdown() }
        var intent = AssistantReviewDocumentsIntent()
        intent.files = [IntentFile(data: zip, filename: "送审原件.zip", type: .zip)]
        _ = try await intent.perform()
        let files = AssistantFileInbox.shared.drain()
        XCTAssertEqual(files.map(\.filename), ["送审原件.zip"])
        XCTAssertEqual(files[0].bytes, zip)
    }
    func testMultiImageAndMixedDocumentSharePreserveBytes() async throws {
        let (session, model, _) = try await setup(); defer { session.shutdown() }
        XCTAssertEqual(model.report?.id, "report", "Official excerpts must not replace the main report action")
        let images = model.files.filter(\.isImage)
        let imageShares = try await model.sharing(images, title: "示例")
        XCTAssertEqual(imageShares.count, 3)
        let documents = model.files.filter(\.isPDF)
        let package = try await model.sharing(documents, title: "示例贸易公司")
        XCTAssertEqual(package.count, 1)
        XCTAssertEqual(package[0].url.lastPathComponent, "示例贸易公司_精选资料(3份).zip")
        let archive = try SafeZIP(data: Data(contentsOf: package[0].url))
        XCTAssertEqual(archive.entries.count, 3)
        XCTAssertTrue(try archive.extract(archive.entries[0]).starts(with: Data("%PDF".utf8)))
    }
    func testFourScreensLightAndDarkAndKeyboardAvoidance() async throws {
        let (session, model, zip) = try await setup(); defer { session.shutdown() }
        let draft = AssistantWorkbenchModel(session: session)
        draft.text = "核对收款方与实控人，重点看转口风险"
        draft.files = [PreparedAttachment(filename: "全套贸易单据.zip", mimeType: "application/zip", bytes: zip), PreparedAttachment(filename: "MT103水单.pdf", mimeType: "application/pdf", bytes: Data("test".utf8)), PreparedAttachment(filename: "贸易合同.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", bytes: Data("test".utf8))]
        let local = try await model.local(model.files.first(where: \.isZIP)!)
        let route = ZIPRoute(file: local, archive: try SafeZIP(data: zip))
        for dark in [false, true] {
            let defaults = UserDefaults(suiteName: "case81-\(UUID())")!
            let app = AppModel(registry: HubRegistry(defaults: defaults), credentialStore: InMemoryCredentialStore())
            try await capture(AnyView(AssistantRootView(session: session, initialDraft: draft).environment(app).environment(ThemePrefs())), name: "01-input", dark: dark)
            let chat = ChatModel(session: session, sessionId: "case81")
            chat.start()
            try await Task.sleep(for: .milliseconds(350))
            try await capture(AnyView(ChatView(session: session, model: chat)), name: "02-capsule", dark: dark, keyboardCheck: true, addPending: { chat.interactor.attachments.add(PreparedAttachment(filename: "补传合同.docx", mimeType: "application/octet-stream", bytes: Data("test".utf8))) })
            chat.stop()
            try await capture(AnyView(SheetHarness { CaseFilesView(model: model, title: "示例贸易公司", initialSelection: ["deliverables:report", "deliverables:shot1", "deliverables:shot2"]) }), name: "03-files", dark: dark)
            try await capture(AnyView(SheetHarness { ZIPContentsView(route: route, title: "示例贸易公司", back: {}) }), name: "04-zip", dark: dark)
        }
    }
    private struct SheetHarness<Content: View>: View {
        @State private var open = true
        @ViewBuilder let content: () -> Content
        var body: some View { Color.gray.opacity(0.2).sheet(isPresented: $open) { content().presentationDetents([.fraction(0.88), .large]).presentationDragIndicator(.visible) } }
    }
    private func capture(_ content: AnyView, name: String, dark: Bool, keyboardCheck: Bool = false, addPending: (() -> Void)? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: content.environment(\.isAssistantMode, true).environment(\.colorScheme, dark ? .dark : .light).hapiTypography().hapiTheme(dark ? .dark : .light))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(1200)); host.view.layoutIfNeeded()
        func save(_ suffix: String = "") throws {
            guard let directory = ProcessInfo.processInfo.environment["HAPI_CASE81_CAPTURE"] else { return }
            let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: root.appendingPathComponent("\(name)\(suffix)-\(dark ? "dark" : "light").png"))
        }
        try save()
        try await captureScreen(name: name, dark: dark)
        if keyboardCheck {
            let input = findTextView(host.view)
            XCTAssertNotNil(input)
            input?.becomeFirstResponder()
            try await Task.sleep(for: .milliseconds(500)); try save("-keyboard"); try await captureScreen(name: name + "-keyboard", dark: dark)
            input?.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(350))
            addPending?()
            try await Task.sleep(for: .milliseconds(350)); try save("-pending"); try await captureScreen(name: name + "-pending", dark: dark)
        }
    }
    private func captureScreen(name: String, dark: Bool) async throws {
        guard let directory = ProcessInfo.processInfo.environment["HAPI_CASE81_SCREEN_CAPTURE"] else { return }
        let request = URL(fileURLWithPath: directory).appendingPathComponent("capture-request.txt")
        try "\(name)-\(dark ? "dark" : "light")".write(to: request, atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: request.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Screen capture watcher did not acknowledge")
    }
    private func findTextView(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap(findTextView).first
    }
}

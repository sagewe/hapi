import Foundation
import HapiClient
@testable import HapiProtocol
import HapiUI
import SwiftUI
import UIKit
import XCTest
@testable import Hapi

@MainActor
final class AssistantWorkbenchTests: XCTestCase {
    actor HTTP: HTTPPerforming {
        var requests: [URLRequest] = []
        var failSend = false
        let summaries: Data
        let machines: Data
        let profile: Data
        init(summaries: Data, machines: Data, profile: Data) { self.summaries = summaries; self.machines = machines; self.profile = profile }
        func failNextSend() { failSend = true }
        func clear() { requests = [] }
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let path = request.url!.path
            var status = 200
            let body: Data
            if path.hasSuffix("/voice/transcription/providers") { body = Data(#"{"providers":[{"id":"openai-compatible","label":"语音","modes":["standard"]}]}"#.utf8) }
            else if path.hasSuffix("hub-settings") { body = profile }
            else if path.hasSuffix("/machines") { body = machines }
            else if path.hasSuffix("/spawn") { body = Data(#"{"type":"success","sessionId":"investigation"}"#.utf8) }
            else if path.hasSuffix("/upload") { body = Data(#"{"success":true,"path":"/test/evidence.pdf"}"#.utf8) }
            else if path.hasSuffix("/messages") && request.httpMethod == "POST" {
                if failSend { failSend = false; status = 503 }
                body = Data((status == 200 ? #"{"ok":true}"# : #"{"error":"retry"}"#).utf8)
            } else { body = summaries }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func setup() async throws -> (HubSession, HTTP) {
        let summaries = [HomeFilterTestData.summary("review", machine: "runner"), HomeFilterTestData.summary("done", machine: "runner")]
        var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionsResponse(sessions: summaries))) as! [String: Any]
        var values = data["sessions"] as! [[String: Any]]
        for i in values.indices {
            var meta = values[i]["metadata"] as? [String: Any] ?? [:]
            meta["name"] = i == 0 ? "示例贸易公司 · 股权与制裁核查" : "跨境付款单据复核"
            meta["tags"] = i == 0 ? ["企业穿透", "高风险"] : ["单据审核"]
            values[i]["metadata"] = meta; values[i]["thinking"] = i == 0
            values[i]["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000) - i * 1200000
        }
        data["sessions"] = values
        let profile = Data(#"{"clientProfile":{"mode":"assistant","defaultAgent":"agy","defaultPermissionMode":"always-proceed","defaultDirectory":"/test","modelPresets":[{"id":"quick","label":"快速","model":"gemini-4-hydrogen-medium","effort":"medium"},{"id":"deep","label":"深度","model":"gemini-4-neon-high","effort":"high","isDefault":true}],"quickActions":[{"id":"company","title":"企业主体与股权穿透","prompt":"核查企业"},{"id":"individual","title":"自然人核查","prompt":"核查自然人"},{"id":"document","title":"单据审核","prompt":"审核单据"},{"id":"sanctions","title":"制裁与高风险筛查","prompt":"筛查制裁"}]}}"#.utf8)
        let http = HTTP(summaries: try JSONSerialization.data(withJSONObject: data),
            machines: try JSONEncoder().encode(MachinesResponse(machines: [HomeFilterTestData.machine("runner", host: "test")])), profile: profile)
        let store = InMemoryCredentialStore(); let url = "http://assistant-workbench-\(UUID()).invalid".lowercased()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"test"}"#.utf8).base64EncodedString()
        try store.store(HubCredentials(hubUrl: url, accessToken: "test", jwt: "e30.\(payload).test"))
        let session = try XCTUnwrap(HubSession(hubUrl: url, credentialStore: store, performer: http))
        await session.refreshClientProfile()
        try await session.sessionStore.refresh()
        return (session, http)
    }
    func testChoosingSceneTypingAndPickingFilesNeverCreatesASession() async throws {
        let (session, http) = try await setup(); defer { session.shutdown() }
        let draft = AssistantWorkbenchModel(session: session)
        await http.clear()
        draft.scene = AssistantScene(action: try XCTUnwrap(session.clientProfile?.quickActions?.first))
        draft.text = "示例公司"
        draft.add(.ready(PreparedAttachment(filename: "evidence.pdf", mimeType: "application/pdf", bytes: Data("test".utf8))))
        draft.cyclePreset()
        XCTAssertNil(draft.allocatedSessionID)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testSendUploadsThenSubmitsAndRetriesSameSession() async throws {
        let (session, http) = try await setup(); defer { session.shutdown() }
        let draft = AssistantWorkbenchModel(session: session)
        draft.text = "核查示例公司"; draft.scene = AssistantScene(action: session.clientProfile!.quickActions![0])
        draft.files = [PreparedAttachment(filename: "evidence.pdf", mimeType: "application/pdf", bytes: Data("test".utf8))]
        await http.clear(); await http.failNextSend()
        let first = await draft.send(); XCTAssertNil(first)
        let second = await draft.send(); XCTAssertEqual(second, "investigation")
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/spawn") }.count, 1)
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/upload") }.count, 1)
        let sends = requests.filter { $0.url!.path.hasSuffix("/messages") }
        let firstBody = try JSONSerialization.jsonObject(with: sends[0].httpBody!) as! [String: Any]
        let secondBody = try JSONSerialization.jsonObject(with: sends[1].httpBody!) as! [String: Any]
        XCTAssertEqual(firstBody["localId"] as? String, secondBody["localId"] as? String)
        XCTAssertTrue((secondBody["text"] as! String).contains("【调查场景：企业股权穿透】"))
        XCTAssertEqual((secondBody["attachments"] as? [Any])?.count, 1)
    }
    func testOnlyOutstandingQuestionsShowWaitingForReply() {
        var summary = HomeFilterTestData.summary("case", machine: "runner")
        summary.pendingRequestsCount = 0; summary.pendingRequestKinds = [.input]; summary.thinking = false
        XCTAssertNil(AssistantHistoryPresentation.status(summary))
        summary.pendingRequestsCount = 1
        XCTAssertEqual(AssistantHistoryPresentation.status(summary), "待回复")
        summary.pendingRequestKinds = [.permission]
        XCTAssertNil(AssistantHistoryPresentation.status(summary))
        summary.pendingRequestsCount = 0; summary.thinking = true; summary.active = true
        XCTAssertEqual(AssistantHistoryPresentation.status(summary), "调查中")
        summary.active = false
        XCTAssertNil(AssistantHistoryPresentation.status(summary))
    }
    func testVoiceRefinementPreservesTypingAndDoesNotCreateASession() async throws {
        let (session, http) = try await setup(); defer { session.shutdown() }
        let draft = AssistantWorkbenchModel(session: session)
        await http.clear()
        draft.text = "请核查"
        draft.beginVoiceEdit("示例公司")
        XCTAssertEqual(draft.text, "请核查 示例公司")
        draft.text += " 的注册号"
        draft.refineVoiceEdit("另一识别结果")
        XCTAssertEqual(draft.text, "请核查 示例公司 的注册号")
        draft.beginVoiceEdit("")
        draft.refineVoiceEdit("补充线索")
        XCTAssertTrue(draft.text.hasSuffix("补充线索"))
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testPhaseClassification() {
        XCTAssertEqual(AssistantInvestigationPhase.title(name: "Bash", input: "python3 scripts/render_pdf.py"), "正在排版生成中文 PDF 报告…")
        XCTAssertEqual(AssistantInvestigationPhase.title(name: "browser_navigate"), "正在访问官网核验原始页面…")
        XCTAssertEqual(AssistantInvestigationPhase.title(name: "read_image"), "正在解析上传单据内容…")
        XCTAssertEqual(AssistantInvestigationPhase.title(name: "search"), "正在检索公开登记与制裁线索…")
    }
    func testLightAndDarkWorkbenchAndDeliveryScreens() async throws {
        let (session, _) = try await setup(); defer { session.shutdown() }
        let defaults = UserDefaults(suiteName: "assistant-ui-fixture-\(UUID())")!
        let app = AppModel(registry: HubRegistry(defaults: defaults), credentialStore: InMemoryCredentialStore())
        let selected = AssistantScene(action: session.clientProfile!.quickActions![0])
        let media = GeneratedMediaLoader(fetch: { _ in (data: Data("%PDF-1.4\n%%EOF".utf8), mimeType: "application/pdf") })
        let report = GeneratedImageBlock(id: "report", localId: nil, createdAt: 0, invokedAt: nil, imageId: "report", fileName: "示例贸易公司 · 股权穿透与制裁核查报告.pdf", mimeType: "application/pdf", source: nil, meta: nil)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let theme: HapiTheme = dark ? .dark : .light
            try await capture(AnyView(AssistantRootView(session: session).environment(app).environment(ThemePrefs())), name: "workbench", dark: dark, scheme: scheme, theme: theme)
            try await capture(AnyView(AssistantRootView(session: session, initialScene: selected).environment(app).environment(ThemePrefs())), name: "scene", dark: dark, scheme: scheme, theme: theme)
            try await capture(AnyView(AssistantRootView(session: session, historyOpen: true).environment(app).environment(ThemePrefs())), name: "history", dark: dark, scheme: scheme, theme: theme)
            try await capture(AnyView(VStack(alignment: .leading, spacing: 20) {
                Text("示例贸易公司 · 股权核查").font(.title3.weight(.semibold))
                AssistantPhaseCard(phase: "正在访问官网核验原始页面…", steps: 5, running: true)
                AssistantPhaseCard(phase: "", steps: 4, running: false)
            }.padding(20)), name: "phase", dark: dark, scheme: scheme, theme: theme)
            try await capture(AnyView(VStack(alignment: .leading, spacing: 20) {
                Text("调查报告已准备好").font(.title3.weight(.semibold))
                GeneratedImageBlockView(block: report)
            }.padding(20).environment(\.isAssistantMode, true).environment(\.chatMedia, media)), name: "report", dark: dark, scheme: scheme, theme: theme)
        }
    }
    private func capture(_ content: AnyView, name: String, dark: Bool, scheme: ColorScheme, theme: HapiTheme) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity).background(AssistantDesign.background)
            .environment(\.colorScheme, scheme).hapiTypography().hapiTheme(theme))
        host.overrideUserInterfaceStyle = window.overrideUserInterfaceStyle
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(350))
        host.view.endEditing(true)
        try await Task.sleep(for: .milliseconds(350)); host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.width, 390, accuracy: 1)
        if let directory = ProcessInfo.processInfo.environment["HAPI_ASSISTANT80_CAPTURE"] {
            let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: root.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }
}

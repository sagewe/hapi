import Foundation
import HapiClient
import HapiProtocol
import Testing

@Suite("Hub client profiles")
struct ClientProfileTests {
    @Test func oldHubAndUnknownModeRemainDeveloper() throws {
        let old = try JSONDecoder().decode(HubSettingsResponse.self, from: Data("{}".utf8))
        #expect(old.clientProfile == nil)
        let unknown = try JSONDecoder().decode(HubSettingsResponse.self,
            from: Data(#"{"clientProfile":{"mode":"future"}}"#.utf8))
        #expect(unknown.clientProfile?.isAssistant == false)
    }
    @Test func assistantRoundTripsAndKeepsOptionalFields() throws {
        let data = Data(#"{"mode":"assistant","defaultAgent":"agy","defaultPermissionMode":"auto","quickActions":[{"id":"company","title":"企业核查","prompt":"核查企业"}]}"#.utf8)
        let profile = try JSONDecoder().decode(ClientProfile.self, from: data)
        #expect(profile.isAssistant)
        #expect(profile.defaultAgent == .agy)
        #expect(profile.quickActions?.first?.title == "企业核查")
        #expect(try JSONDecoder().decode(ClientProfile.self, from: JSONEncoder().encode(profile)) == profile)
    }
    @Test func codexPreservesExplicitNoApprovalIntent() throws {
        for mode in ["always-proceed", "yolo"] {
            let profile = try JSONDecoder().decode(ClientProfile.self,
                from: Data("{\"mode\":\"assistant\",\"defaultPermissionMode\":\"\(mode)\"}".utf8))
            #expect(profile.assistantPermissionMode(for: .codex) == .yolo)
        }
        let automatic = try JSONDecoder().decode(ClientProfile.self,
            from: Data(#"{"mode":"assistant","defaultPermissionMode":"auto"}"#.utf8))
        #expect(automatic.assistantPermissionMode(for: .codex) == .default)
        #expect(automatic.assistantPermissionMode(for: .agy) == .auto)
    }
    @Test func executionPrivacyIsHubScopedAndCanBeDisabled() throws {
        for (json, hidden) in [(#"{"mode":"assistant"}"#, true),
            (#"{"mode":"assistant","hideExecutionDetails":false}"#, false),
            (#"{"mode":"developer","hideExecutionDetails":true}"#, false)] {
            let profile = try JSONDecoder().decode(ClientProfile.self, from: Data(json.utf8))
            #expect(profile.hidesExecutionDetails == hidden)
        }
    }
    @Test func presetsUseExplicitDefaultAndMatchNativeBaseModel() throws {
        let profile = try JSONDecoder().decode(ClientProfile.self, from: Data(#"{"mode":"assistant","modelPresets":[{"id":"quick","label":"快速","model":"gemini-4-hydrogen-medium","effort":"medium"},{"id":"deep","label":"深度","model":"gemini-4-neon-high","effort":"high","isDefault":true}]}"#.utf8))
        #expect(profile.defaultModelPreset?.id == "deep")
        #expect(profile.modelPresets?.first?.matches(model: "gemini-4-hydrogen", effort: "medium") == true)
        #expect(profile.modelPresets?.first?.matches(model: "gemini-4-hydrogen", effort: "high") == false)
        #expect(try JSONDecoder().decode(ClientProfile.self, from: JSONEncoder().encode(profile)) == profile)
    }
    @Test func presetSwitchIsAnAtomicModelAndEffortRequest() async throws {
        let harness = try makeHarness(jwt: freshJWT())
        await harness.performer.enqueue(json: #"{"ok":true}"#)
        try await harness.client.setModel(sessionId: "investigation", model: .id("gemini-4-hydrogen-medium"), effort: "medium")
        let requests = await harness.performer.requests
        #expect(requests.count == 1)
        let body = try #require(requests.first?.httpBody)
        let value = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(value?["model"] == "gemini-4-hydrogen-medium")
        #expect(value?["effort"] == "medium")
    }
    @Test func authenticatedSettingsEndpoint() async throws {
        let token = freshJWT()
        let harness = try makeHarness(jwt: token)
        await harness.performer.enqueue(json: #"{"clientProfile":{"mode":"assistant"}}"#)
        #expect(try await harness.client.hubSettings().clientProfile?.isAssistant == true)
        let request = await harness.performer.requests.first
        #expect(request?.url?.path == "/v1/settings")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }
}

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
    @Test func authenticatedSettingsEndpoint() async throws {
        let token = freshJWT()
        let harness = try makeHarness(jwt: token)
        await harness.performer.enqueue(json: #"{"clientProfile":{"mode":"assistant"}}"#)
        #expect(try await harness.client.hubSettings().clientProfile?.isAssistant == true)
        let request = await harness.performer.requests.first
        #expect(request?.url?.path == "/api/hub-settings")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }
}

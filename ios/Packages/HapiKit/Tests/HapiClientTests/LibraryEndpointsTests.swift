import Foundation
import HapiProtocol
import Testing
@testable import HapiClient

@Suite("LibraryEndpoints")
struct LibraryEndpointsTests {
    private actor CapturePerformer: HTTPPerforming {
        private(set) var lastRequest: URLRequest?
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            let url = request.url ?? URL(string: "https://example.invalid")!
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(#"{"files":[]}"#.utf8), resp)
        }
    }

    @Test("recentDeliverables passes limit via URLQueryItem without crashing URLComponents")
    func recentDeliverablesQuery() async throws {
        let performer = CapturePerformer()
        let baseURL = URL(string: "https://qiqiwork.sagewe.tech")!
        let store = InMemoryCredentialStore()
        let payload = Data(#"{"uid":1,"exp":4102444800,"ns":"compliance"}"#.utf8).base64EncodedString()
        try store.store(HubCredentials(
            hubUrl: baseURL.absoluteString,
            accessToken: "test-token",
            jwt: "e30.\(payload).sig"
        ))
        let auth = AuthManager(
            baseURL: baseURL,
            credentialStore: store,
            performer: performer
        )
        let client = APIClient(baseURL: baseURL, authManager: auth, performer: performer)

        let files = try await client.recentDeliverables(limit: 50)
        #expect(files.isEmpty)
        let req = await performer.lastRequest
        #expect(req?.url?.path == "/v1/library/deliverables")
        #expect(req?.url?.query == "limit=50")
    }
}

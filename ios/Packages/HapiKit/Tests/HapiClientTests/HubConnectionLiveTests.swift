import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import HapiProtocol
@testable import HapiClient

private struct PrivateBlocked: HTTPPerforming {
    let host: String
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == host { throw URLError(.cannotConnectToHost) }
        return try await URLSessionHTTPPerformer.shared.perform(request)
    }
}

private final class LiveRoutingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(31) }
}

@Suite("Opt-in live Hub routing")
struct HubConnectionLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAPI_ROUTE_LIVE_CONFIG"] != nil))
    func verifiesDirectAndFallbackAgainstTheSameLiveHub() async throws {
        struct Config: Decodable { let origin: URL; let jwt: String }
        struct Info: Decodable { let hubId: String; let privateUrl: URL }
        let path = try #require(ProcessInfo.processInfo.environment["HAPI_ROUTE_LIVE_CONFIG"])
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        func client(_ http: any HTTPPerforming, clock: LiveRoutingClock = LiveRoutingClock()) throws -> APIClient {
            let router = HubConnectionRouter(canonicalURL: config.origin, performer: http, persistent: false, now: { clock.now() })
            let routed = RoutingHTTPPerformer(router: router, underlying: http)
            let store = InMemoryCredentialStore()
            try store.store(HubCredentials(hubUrl: config.origin.absoluteString, accessToken: "unused-live-probe", jwt: config.jwt))
            return APIClient(baseURL: config.origin, authManager: AuthManager(baseURL: config.origin, credentialStore: store, performer: routed),
                             performer: routed, connection: router)
        }
        let clock = LiveRoutingClock()
        let direct = try client(URLSessionHTTPPerformer.shared, clock: clock)
        let info: Info = try await direct.request(.get, "/api/connection")
        #expect(direct.baseURL == config.origin)
        await direct.connection?.refreshDiagnostics(force: true)
        let measurements = try #require(await direct.connection?.diagnostics())
        #expect(measurements.privateMeasurement?.outcome == .reachable)
        #expect(measurements.publicMeasurement?.outcome == .reachable)
        print("Measured HTTP ms private=\(measurements.privateMeasurement?.milliseconds ?? -1) public=\(measurements.publicMeasurement?.milliseconds ?? -1)")
        // A cold private handshake may exceed the one-second routing budget.
        // Real health requests remain real; advance only policy time so the
        // documented spaced-recovery checks need no minute-long test sleep.
        for _ in 0..<3 {
            if await direct.connection?.status().isPrivate == true { break }
            clock.advance()
            let _: Info = try await direct.request(.get, "/api/connection")
        }
        #expect(await direct.connection?.status().isPrivate == true)
        let _: JSONValue = try await direct.request(.get, "/api/sessions")
        let socket = try await direct.connectionRequest(URLRequest(url: config.origin.appendingPathComponent("api/voice/asr-ws")))
        #expect(socket.url?.host == info.privateUrl.host)
        let fallback = try client(PrivateBlocked(host: try #require(info.privateUrl.host)))
        let viaPublic: Info = try await fallback.request(.get, "/api/connection")
        #expect(viaPublic.hubId == info.hubId)
        #expect(await fallback.connection?.status().isPrivate == false)
        #expect(fallback.baseURL == direct.baseURL)
    }
}

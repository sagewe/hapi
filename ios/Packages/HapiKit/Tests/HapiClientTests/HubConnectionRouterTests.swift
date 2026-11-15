import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HapiClient

private final class RouteClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    private var monotonic: TimeInterval = 500
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func uptime() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return monotonic }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds); monotonic += seconds }
    func advanceUptimeMs(_ ms: Int) { lock.lock(); defer { lock.unlock() }; monotonic += Double(ms) / 1000.0 }
}

private actor RouteHTTP: HTTPPerforming {
    var directUp = true
    var sameIdentity = true
    var publicUp = true
    var directTimeoutCount = 0
    var directLatencyMs = 0
    var publicLatencyMs = 0
    var privateOrigin = "https://direct.example.test"
    var lanAdvertised = true
    var delayLAN = false
    func slowLAN() { delayLAN = true }
    func noLAN() { lanAdvertised = false }
    func publicRestore() { publicUp = true }
    var onAdvanceUptimeMs: (@Sendable (Int) -> Void)?
    private(set) var requests: [URLRequest] = []
    func direct(_ up: Bool) { directUp = up }
    func mismatch() { sameIdentity = false }
    func publicDown() { publicUp = false }
    func directTimeouts(_ count: Int) { directTimeoutCount = count }
    func latencies(directMs: Int, publicMs: Int, clock: RouteClock) {
        directLatencyMs = directMs
        publicLatencyMs = publicMs
        onAdvanceUptimeMs = { clock.advanceUptimeMs($0) }
    }
    func advertise(_ origin: String) { privateOrigin = origin }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        if url.host == "direct.example.test" || url.host == "direct2.example.test" {
            if delayLAN { try await Task.sleep(for: .seconds(10)) }
            if directLatencyMs > 0 { onAdvanceUptimeMs?(directLatencyMs) }
            if directTimeoutCount > 0 {
                directTimeoutCount -= 1
                throw URLError(.timedOut)
            }
            if !directUp { throw URLError(.networkConnectionLost) }
        }
        if url.host == "public.example.test" {
            if publicLatencyMs > 0 { onAdvanceUptimeMs?(publicLatencyMs) }
            if !publicUp { throw URLError(.cannotConnectToHost) }
        }
        let body: String
        if url.path == "/api/connection" { body = "{\"hubId\":\"same-hub\",\"privateUrl\":\"https://tailscale.example.test\",\"lanUrl\":\(lanAdvertised ? "\"\(privateOrigin)\"" : "null")}" }
        else if url.path == "/health" { body = "{\"status\":\"ok\",\"hubId\":\"\(sameIdentity ? "same-hub" : "wrong-hub")\"}" }
        else { body = #"{"ok":true}"# }
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

private struct ConnectedSSE: SSETransport {
    func connect(_ request: URLRequest) -> AsyncThrowingStream<SSETransportEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.connected(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
            let task = Task { try? await Task.sleep(for: .seconds(60)); continuation.finish() }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Hub dual endpoint routing")
struct HubConnectionRouterTests {
    private let canonical = URL(string: "https://public.example.test")!

    @Test func measurementsAreReadOnlyAndRespectForcedModes() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        let direct = try await router.resolve(token: "test-only")
        let first = await router.diagnostics()
        #expect(first.lanMeasurement?.outcome == .reachable)
        #expect((first.lanMeasurement?.milliseconds ?? -1) >= 0)
        await http.direct(false)
        await router.refreshDiagnostics(force: true)
        let measured = await router.diagnostics()
        #expect(measured.isPrivate)
        #expect(measured.lanMeasurement?.outcome == .unavailable)
        #expect(measured.publicMeasurement?.outcome == .reachable)
        #expect(measured.reason == first.reason)
        await router.setMode(.publicOnly)
        let count = await http.requests.filter { $0.url?.host == direct.host }.count
        await router.refreshDiagnostics(force: true)
        #expect(await http.requests.filter { $0.url?.host == direct.host }.count == count)
        await router.setMode(.lanOnly)
        let publicCount = await http.requests.filter { $0.url?.host == canonical.host }.count
        await router.refreshDiagnostics(force: true)
        #expect(await http.requests.filter { $0.url?.host == canonical.host }.count == publicCount)
    }

    @Test func activeEventRouteIsDistinguishedFromTheNextSelectedRoute() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        let direct = try await router.resolve(token: "test-only")
        let id = UUID()
        await router.eventStreamOpened(id: id, origin: direct)
        await router.setMode(.publicOnly)
        let snapshot = await router.diagnostics()
        #expect(!snapshot.isPrivate)
        #expect(snapshot.activeEventIsPrivate == true)
        #expect(snapshot.currentMeasurement?.url == direct)
        await router.eventStreamClosed(id: UUID())
        #expect(await router.diagnostics().activeEventIsPrivate == true)
        await router.eventStreamClosed(id: id)
        #expect(await router.diagnostics().activeEventIsPrivate == nil)
    }

    @Test func verifiesIdentityBeforePrivateAuthAndPreservesRequestBytes() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        let performer = RoutingHTTPPerformer(router: router, underlying: http)
        var request = URLRequest(url: canonical.appendingPathComponent("api/messages"))
        request.httpMethod = "POST"; request.httpBody = Data([0, 1, 2, 255])
        request.setValue("Bearer test-only", forHTTPHeaderField: "Authorization")
        _ = try await performer.perform(request)
        let requests = await http.requests
        #expect(requests.map { $0.url?.path } == ["/api/connection", "/health", "/api/messages"])
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests.last?.url?.host == "direct.example.test")
        #expect(requests.last?.httpBody == request.httpBody)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
    }

    @Test func mismatchedHubNeverReceivesCredentials() async throws {
        let http = RouteHTTP(); await http.mismatch()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        #expect(try await router.resolve(token: "test-only") == canonical)
        #expect(await http.requests.filter { $0.url?.host == "direct.example.test" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func failedReadFallsBackButUncertainMutationIsNeverReplayed() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        _ = try await router.resolve(token: "test-only")
        await http.direct(false)
        let performer = RoutingHTTPPerformer(router: router, underlying: http)
        var write = URLRequest(url: canonical.appendingPathComponent("api/messages")); write.httpMethod = "POST"
        #expect(await capturedError { try await performer.perform(write) } is URLError)
        #expect(await http.requests.filter { $0.url?.path == "/api/messages" }.count == 1)
        let read = URLRequest(url: canonical.appendingPathComponent("api/sessions"))
        _ = try await performer.perform(read)
        #expect(await http.requests.last?.url?.host == "public.example.test")
        let fresh = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        await http.direct(true); _ = try await fresh.resolve(token: "test-only"); await http.direct(false)
        _ = try await RoutingHTTPPerformer(router: fresh, underlying: http).perform(read)
        #expect(await http.requests.suffix(2).map { $0.url?.host } == ["direct.example.test", "public.example.test"])
    }

    @Test func publicConnectionNeedsTwoSpacedSuccessesBeforeReturningPrivate() async throws {
        let clock = RouteClock(); let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false, now: { clock.now() })
        let direct = try await router.resolve(token: "test-only")
        await router.failed(direct)
        #expect(try await router.resolve() == canonical)
        clock.advance(16)
        #expect(try await router.resolve() == canonical)
        clock.advance(31)
        #expect(try await router.resolve() == direct)
        await http.publicDown(); clock.advance(301)
        #expect(try await router.resolve(token: "test-only") == direct)
    }

    @Test func explicitModesAndWebSocketsUseTheSameVerifiedEndpoint() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        let direct = try await router.resolve(token: "test-only")
        let request = URLRequest(url: URL(string: "wss://public.example.test/api/ws?session=a%2Fb")!)
        #expect(router.rewrite(request, to: direct).url?.absoluteString == "wss://direct.example.test/api/ws?session=a%2Fb")
        await router.setMode(.publicOnly)
        #expect(try await router.resolve() == canonical)
        await router.setMode(.lanOnly); await http.direct(false)
        #expect(await capturedError { try await router.resolve() } is URLError)
    }

    @Test func concurrentRequestsShareDiscoveryAndPublicFailureCanUseVerifiedPrivate() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        await http.direct(false)
        try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<10 { group.addTask { try await router.resolve(token: "test-only") } }
            for try await origin in group { #expect(origin == canonical) }
        }
        #expect(await http.requests.filter { $0.url?.path == "/api/connection" }.count == 1)
        await http.direct(true); await http.publicDown()
        _ = try await RoutingHTTPPerformer(router: router, underlying: http).perform(URLRequest(url: canonical.appendingPathComponent("api/sessions")))
        #expect(await http.requests.last?.url?.host == "tailscale.example.test")
    }

    @Test func routeChangeClosesTheOldEventStreamForCursorPreservingReconnect() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        let transport = RoutingSSETransport(router: router, underlying: ConnectedSSE(), recheckInterval: .milliseconds(5))
        var request = URLRequest(url: URL(string: canonical.absoluteString + "/api/events?all=true&token=test-only")!)
        request.setValue("old-event-cursor", forHTTPHeaderField: "Last-Event-ID")
        var iterator = transport.connect(request).makeAsyncIterator()
        if case .connected(let response) = try await iterator.next() {
            #expect(response.url?.host == "direct.example.test")
        } else { Issue.record("Missing SSE handshake") }
        #expect(await router.diagnostics().activeEventIsPrivate == true)
        await router.setMode(.publicOnly)
        let error = await capturedError { try await iterator.next() }
        #expect(error is URLError)
        #expect(await router.diagnostics().activeEventIsPrivate == nil)
        #expect(router.rewrite(request, to: canonical).value(forHTTPHeaderField: "Last-Event-ID") == "old-event-cursor")
    }

    @Test func cachedDiscoveryWorksAfterRelaunchWithoutContactingPublicRelay() async throws {
        let key = "run.hapi.connection.\(canonical.absoluteString)"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key); defaults.removeObject(forKey: key + ".mode")
        defer { defaults.removeObject(forKey: key); defaults.removeObject(forKey: key + ".mode") }
        let firstHTTP = RouteHTTP()
        let first = HubConnectionRouter(canonicalURL: canonical, performer: firstHTTP)
        _ = try await first.resolve(token: "test-only")
        let offlinePublic = RouteHTTP(); await offlinePublic.publicDown()
        let relaunched = HubConnectionRouter(canonicalURL: canonical, performer: offlinePublic)
        #expect(try await relaunched.resolve(token: "test-only").host == "direct.example.test")
        #expect(await offlinePublic.requests.allSatisfy { $0.url?.host == "direct.example.test" })
    }

    @Test func singlePeriodicProbeGlitchKeepsActivePrivateRouteUntilSecondFailureOrNetworkChange() async throws {
        let clock = RouteClock(); let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false,
                                         now: { clock.now() }, uptime: { clock.uptime() })
        let direct = try await router.resolve(token: "test-only")
        #expect(direct.host == "direct.example.test")

        await http.direct(false)
        clock.advance(31)
        #expect(try await router.resolve() == direct)

        clock.advance(11)
        #expect(try await router.resolve() == canonical)
        #expect(await router.diagnostics().reason == .privateUnavailable)

        await http.direct(true)
        clock.advance(31); _ = try await router.resolve()
        clock.advance(31); #expect(try await router.resolve() == direct)

        await http.direct(false)
        await router.networkChanged()
        #expect(try await router.resolve() == canonical)
    }

    @Test func periodicDiscoveryRefreshRunsInBackgroundAndAppliesChangedOrigin() async throws {
        let clock = RouteClock(); let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false,
                                         now: { clock.now() }, uptime: { clock.uptime() })
        let direct = try await router.resolve(token: "test-only")
        #expect(direct.host == "direct.example.test")

        await http.advertise("https://direct2.example.test")
        clock.advance(301)
        // Resolve returns cached verified direct route without waiting on discovery;
        // once background discovery finishes, the updated private origin takes effect.
        _ = try await router.resolve(token: "test-only")
        await router.awaitBackgroundTasksForTesting()
        #expect(try await router.resolve(token: "test-only").host == "direct2.example.test")
    }

    @Test func coldLANTimeoutUsesPublicWithoutTryingTailscale() async throws {
        let clock = RouteClock(); let http = RouteHTTP()
        await http.directTimeouts(1)
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false, now: { clock.now() })
        #expect(try await router.resolve(token: "test-only") == canonical)
        #expect(await http.requests.allSatisfy { $0.url?.host != "tailscale.example.test" })
        clock.advance(31); #expect(try await router.resolve() == canonical)
        clock.advance(31); #expect(try await router.resolve().host == "direct.example.test")
    }

    @Test func outsideHomePrefersPublicAndOnlyFallsBackAfterFailure() async throws {
        let clock = RouteClock(); let http = RouteHTTP(); await http.noLAN()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false, now: { clock.now() })
        #expect(try await router.resolve(token: "test-only") == canonical)
        #expect(await http.requests.allSatisfy { $0.url?.host != "tailscale.example.test" })
        await http.publicDown(); await router.failed(canonical)
        #expect(try await router.resolve().host == "tailscale.example.test")
        #expect(await router.diagnostics().selectedRoute == .tailscale)
        await http.publicRestore()
        clock.advance(31); #expect(try await router.resolve().host == "tailscale.example.test")
        clock.advance(31); #expect(try await router.resolve() == canonical)
    }

    @Test func forcedUnavailableLANDoesNotSilentlyReturnPublicOnSecondAttempt() async throws {
        let clock = RouteClock(); let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false, now: { clock.now() })
        _ = try await router.resolve(token: "test-only")
        await router.setMode(.lanOnly); await http.direct(false)
        #expect(await capturedError { try await router.resolve() } is URLError)
        #expect(await capturedError { try await router.resolve() } is URLError)
    }
    @Test func manualTailscaleSelectionClosesLANStreamWithoutMarkingNewRouteFailed() async throws {
        let http = RouteHTTP()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        let transport = RoutingSSETransport(router: router, underlying: ConnectedSSE(), recheckInterval: .milliseconds(5))
        let request = URLRequest(url: URL(string: canonical.absoluteString + "/api/events?all=true&token=test-only")!)
        var iterator = transport.connect(request).makeAsyncIterator()
        _ = try await iterator.next()
        #expect(await router.diagnostics().activeRoute == .lan)
        await router.setMode(.privateOnly)
        #expect(await capturedError { try await iterator.next() } is URLError)
        #expect(try await router.resolve().host == "tailscale.example.test")
        #expect(await router.diagnostics().reason == .forcedPrivate)
    }

    @Test func changingModeCancelsInFlightLANProbeWithoutRestoringOldSelection() async throws {
        let http = RouteHTTP(); await http.slowLAN()
        let router = HubConnectionRouter(canonicalURL: canonical, performer: http, persistent: false)
        let task = Task { try await router.resolve(token: "test-only") }
        for _ in 0..<1000 {
            if await http.requests.contains(where: { $0.url?.path == "/health" }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await router.setMode(.publicOnly)
        _ = await capturedError { try await task.value }
        #expect(try await router.resolve() == canonical)
        #expect(await router.diagnostics().mode == .publicOnly)
        #expect(await router.diagnostics().selectedRoute == .relay)
    }

}

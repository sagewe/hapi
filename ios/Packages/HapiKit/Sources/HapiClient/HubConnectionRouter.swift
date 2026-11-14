import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HubConnectionMode: String, CaseIterable, Sendable { case automatic, privateOnly, publicOnly }

/// Keeps logical Hub identity, auth storage and all stores on the paired origin.
/// Only transports rewrite origins, after checking the same public Hub identity.
public actor HubConnectionRouter {
    private struct Advertisement: Codable { let hubId: String; let privateUrl: URL? }
    public let canonicalURL: URL
    private let performer: any HTTPPerforming
    private let defaults: UserDefaults?
    private let key: String
    private let now: @Sendable () -> Date
    private var advertisement: Advertisement?
    private var selected: URL
    private var mode: HubConnectionMode
    private var lastDiscovery = Date.distantPast
    private var lastProbe = Date.distantPast
    private var failuresUntil = Date.distantPast
    private var successes = 0
    private var initialized = false
    private var flight: Task<URL, Error>?
    private var diagnosticsFlight: Task<Void, Never>?
    private var lastDiagnostics = Date.distantPast
    private var privateMeasurement: HubEndpointMeasurement?
    private var publicMeasurement: HubEndpointMeasurement?
    private var reason: HubConnectionDiagnostics.Reason = .starting {
        didSet { if reason != oldValue { reasonUpdatedAt = now() } }
    }
    private var reasonUpdatedAt: Date?
    private var activeGlobalStream: (id: UUID, origin: URL)?

    public init(canonicalURL: URL, performer: any HTTPPerforming = URLSessionHTTPPerformer.shared,
                persistent: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) {
        self.canonicalURL = canonicalURL
        self.selected = canonicalURL
        self.performer = performer
        self.now = now
        let defaults: UserDefaults? = persistent ? .standard : nil
        self.defaults = defaults
        key = "run.hapi.connection.\(canonicalURL.absoluteString)"
        advertisement = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Advertisement.self, from: $0) }
        mode = defaults?.string(forKey: key + ".mode").flatMap(HubConnectionMode.init(rawValue:)) ?? .automatic
    }

    public func status() -> (mode: HubConnectionMode, isPrivate: Bool) { (mode, selected != canonicalURL) }

    public func diagnostics() -> HubConnectionDiagnostics {
        HubConnectionDiagnostics(mode: mode, isPrivate: selected != canonicalURL, reason: reason,
                                 privateMeasurement: privateMeasurement, publicMeasurement: publicMeasurement,
                                 activeEventIsPrivate: activeGlobalStream.map { $0.origin != canonicalURL }, reasonUpdatedAt: reasonUpdatedAt)
    }

    func eventStreamOpened(id: UUID, origin: URL) { activeGlobalStream = (id, origin) }
    func eventStreamClosed(id: UUID) { if activeGlobalStream?.id == id { activeGlobalStream = nil } }

    /// Read-only diagnostics never count toward routing hysteresis or force a
    /// route change. Callers own the foreground-only refresh loop.
    public func refreshDiagnostics(force: Bool = false) async {
        if let diagnosticsFlight { await diagnosticsFlight.value; return }
        guard force || now().timeIntervalSince(lastDiagnostics) >= 15 else { return }
        lastDiagnostics = now()
        let task = Task {
            if self.mode != .privateOnly { _ = await self.probe(self.canonicalURL, timeout: 3) }
            if self.mode != .publicOnly, let direct = self.advertisement?.privateUrl, Self.validPrivateOrigin(direct) {
                _ = await self.probe(direct, timeout: 3)
            }
        }
        diagnosticsFlight = task
        await task.value
        if diagnosticsFlight == task { diagnosticsFlight = nil }
    }

    private func probe(_ origin: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: origin.appendingPathComponent("health"))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let started = ProcessInfo.processInfo.systemUptime
        var outcome: HubEndpointMeasurement.Outcome = .unavailable
        var reused: Bool?
        do {
            let data: Data; let response: HTTPURLResponse
            if let performer = performer as? URLSessionHTTPPerformer {
                (data, response, reused) = try await performer.measuredProbe(request)
            } else { (data, response) = try await performer.perform(request) }
            struct Health: Decodable { let status: String; let hubId: String? }
            if response.statusCode != 200 { outcome = .httpError(response.statusCode) }
            else if let health = try? JSONDecoder().decode(Health.self, from: data), health.status == "ok" {
                if let expected = advertisement?.hubId, health.hubId != expected { outcome = .identityMismatch }
                else { outcome = .reachable }
            }
        } catch {
            if (error as? URLError)?.code == .timedOut { outcome = .timeout }
        }
        let measurement = HubEndpointMeasurement(url: origin, checkedAt: now(),
            milliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000), outcome: outcome, reusedConnection: reused)
        if origin == canonicalURL { publicMeasurement = measurement } else { privateMeasurement = measurement }
        return outcome == .reachable
    }

    /// A new pairing must not inherit endpoint trust from previous credentials
    /// at the same public address. The old session is torn down by AppModel.
    public nonisolated static func forget(hubURL: String) {
        let origin = HubURLNormalization.normalize(hubURL) ?? hubURL
        let key = "run.hapi.connection.\(origin)"
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key + ".mode")
    }

    public func setMode(_ value: HubConnectionMode) {
        mode = value
        defaults?.set(value.rawValue, forKey: key + ".mode")
        flight?.cancel(); flight = nil
        lastDiscovery = .distantPast
        lastProbe = .distantPast; failuresUntil = .distantPast; initialized = false; successes = 0
        if value == .publicOnly { selected = canonicalURL }
        reason = value == .publicOnly ? .forcedPublic : value == .privateOnly ? .forcedPrivate : .starting
    }

    public func resolve(token: String? = nil) async throws -> URL {
        if mode == .publicOnly { return canonicalURL }
        if let flight { return try await flight.value }
        let task = Task { try await self.choose(token: token) }
        flight = task
        defer { if flight == task { flight = nil } }
        return try await task.value
    }

    private func choose(token: String?) async throws -> URL {
        let reference = now()
        if mode == .privateOnly && advertisement == nil { throw URLError(.cannotConnectToHost) }
        if mode == .automatic, let token, reference.timeIntervalSince(lastDiscovery) >= 300,
           advertisement?.privateUrl == nil || initialized {
            lastDiscovery = reference
            var request = URLRequest(url: canonicalURL.appendingPathComponent("api/connection"))
            request.timeoutInterval = 2
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await performer.perform(request), response.statusCode == 200,
               let candidate = try? JSONDecoder().decode(Advertisement.self, from: data),
               !candidate.hubId.isEmpty,
               candidate.privateUrl.map(Self.validPrivateOrigin) ?? true {
                try Task.checkCancellation()
                if advertisement?.hubId != candidate.hubId || advertisement?.privateUrl != candidate.privateUrl {
                    selected = canonicalURL; lastProbe = .distantPast; initialized = false; successes = 0
                }
                advertisement = candidate
                if let encoded = try? JSONEncoder().encode(candidate) { defaults?.set(encoded, forKey: key) }
            }
        }
        guard let advertisement, let direct = advertisement.privateUrl, Self.validPrivateOrigin(direct) else {
            reason = .noPrivateEndpoint
            if mode == .privateOnly { throw URLError(.cannotConnectToHost) }
            return canonicalURL
        }
        if reference >= failuresUntil && reference.timeIntervalSince(lastProbe) >= 30 {
            lastProbe = reference
            let verified = await probe(direct, timeout: 1)
            try Task.checkCancellation()
            if verified {
                successes += 1
                if !initialized || selected == direct || successes >= 2 || mode == .privateOnly {
                    selected = direct; reason = mode == .privateOnly ? .forcedPrivate : .privateVerified
                } else { reason = .awaitingRecovery }
            } else {
                successes = 0; selected = canonicalURL
                reason = .privateUnavailable
            }
            initialized = true
        }
        if mode == .privateOnly && selected != direct { throw URLError(.cannotConnectToHost) }
        return selected
    }

    public func failed(_ origin: URL) {
        if origin == selected {
            selected = canonicalURL; successes = 0; initialized = true
            failuresUntil = now().addingTimeInterval(15)
            lastProbe = .distantPast
            if origin == canonicalURL { initialized = false; failuresUntil = .distantPast }
            reason = origin == canonicalURL ? .publicNetworkFailure : .privateNetworkFailure
        }
    }

    public func networkChanged() { lastProbe = .distantPast; failuresUntil = .distantPast }

    private static func validPrivateOrigin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            && ["", "/"].contains(url.path) && url.query == nil && url.fragment == nil
    }

    public nonisolated func rewrite(_ request: URLRequest, to origin: URL) -> URLRequest {
        guard let url = request.url, url.host == canonicalURL.host, url.port == canonicalURL.port,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return request }
        let websocket = parts.scheme == "ws" || parts.scheme == "wss"
        parts.scheme = websocket ? (origin.scheme == "https" ? "wss" : "ws") : origin.scheme
        parts.host = origin.host; parts.port = origin.port
        guard let target = parts.url else { return request }
        var copy = request; copy.url = target
        return copy
    }

    public nonisolated static func isNetworkFailure(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}

public struct RoutingNetworkPathObserver: NetworkPathObserving {
    let router: HubConnectionRouter
    let underlying: any NetworkPathObserving
    public init(router: HubConnectionRouter, underlying: any NetworkPathObserving) { self.router = router; self.underlying = underlying }
    public func pathUpdates() -> AsyncStream<NetworkPathUpdate> {
        AsyncStream { continuation in
            let task = Task {
                var last: NetworkPathUpdate?
                for await update in underlying.pathUpdates() {
                    if let last, update.requiresReconnect(from: last) { await router.networkChanged() }
                    last = update
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct RoutingHTTPPerformer: HTTPPerforming {
    private let router: HubConnectionRouter
    private let underlying: any HTTPPerforming
    public init(router: HubConnectionRouter, underlying: any HTTPPerforming) { self.router = router; self.underlying = underlying }
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let bearer = request.value(forHTTPHeaderField: "Authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let origin = try await router.resolve(token: bearer)
        do { return try await underlying.perform(router.rewrite(request, to: origin)) }
        catch {
            guard HubConnectionRouter.isNetworkFailure(error) else { throw error }
            await router.failed(origin)
            // Reads and auth exchanges are safe to repeat. Never replay an
            // uncertain message, approval, terminal command or other mutation.
            let safe = request.httpMethod == "GET" || request.httpMethod == "HEAD" || request.url?.path == "/api/auth"
            let mode = await router.status().mode
            if safe, mode == .automatic {
                let alternative = try await router.resolve(token: bearer)
                if alternative != origin { return try await underlying.perform(router.rewrite(request, to: alternative)) }
            }
            throw error
        }
    }
}

public struct RoutingSSETransport: SSETransport {
    private let router: HubConnectionRouter
    private let underlying: any SSETransport
    private let recheckInterval: Duration
    public init(router: HubConnectionRouter, underlying: any SSETransport = URLSessionSSETransport(), recheckInterval: Duration = .seconds(15)) {
        self.router = router; self.underlying = underlying; self.recheckInterval = recheckInterval
    }
    public func connect(_ request: URLRequest) -> AsyncThrowingStream<SSETransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var origin: URL?
                let streamId = UUID()
                let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                let isGlobal = query.contains { $0.name == "all" && $0.value == "true" }
                do {
                    let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst(7)) }
                        ?? query.first { $0.name == "token" }?.value
                    let selected = try await router.resolve(token: token)
                    origin = selected
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await event in underlying.connect(router.rewrite(request, to: selected)) {
                                try Task.checkCancellation()
                                if isGlobal, case .connected(let response) = event, response.statusCode == 200 {
                                    await router.eventStreamOpened(id: streamId, origin: selected)
                                }
                                continuation.yield(event)
                            }
                        }
                        group.addTask {
                            while !Task.isCancelled {
                                try await Task.sleep(for: recheckInterval)
                                if try await router.resolve(token: token) != selected { throw URLError(.networkConnectionLost) }
                            }
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                    if isGlobal { await router.eventStreamClosed(id: streamId) }
                    continuation.finish()
                } catch {
                    if isGlobal { await router.eventStreamClosed(id: streamId) }
                    // A deliberate route change must not mark the newly selected
                    // endpoint down. Actual transport failures invalidate only it.
                    if let origin, HubConnectionRouter.isNetworkFailure(error),
                       (await router.status()).isPrivate == (origin != router.canonicalURL) { await router.failed(origin) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HubConnectionMode: String, CaseIterable, Sendable { case automatic, lanOnly, privateOnly, publicOnly }
public enum HubConnectionRoute: String, Sendable { case lan, tailscale, relay }

/// The paired origin remains the identity for authentication, drafts and caches.
/// Alternate origins receive credentials only after TLS and Hub identity checks.
public actor HubConnectionRouter {
    private struct Advertisement: Codable, Equatable {
        let hubId: String
        let privateUrl: URL?
        let lanUrl: URL?

        private enum CodingKeys: String, CodingKey {
            case hubId, hub_id
            case privateUrl, private_url
            case lanUrl, lan_url
        }

        init(hubId: String, privateUrl: URL?, lanUrl: URL?) {
            self.hubId = hubId
            self.privateUrl = privateUrl
            self.lanUrl = lanUrl
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hubId = try c.decodeIfPresent(String.self, forKey: .hub_id)
                ?? c.decode(String.self, forKey: .hubId)
            privateUrl = try c.decodeIfPresent(URL.self, forKey: .private_url)
                ?? c.decodeIfPresent(URL.self, forKey: .privateUrl)
            lanUrl = try c.decodeIfPresent(URL.self, forKey: .lan_url)
                ?? c.decodeIfPresent(URL.self, forKey: .lanUrl)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(hubId, forKey: .hubId)
            try c.encodeIfPresent(privateUrl, forKey: .privateUrl)
            try c.encodeIfPresent(lanUrl, forKey: .lanUrl)
        }
    }
    public let canonicalURL: URL
    private let performer: any HTTPPerforming
    private let defaults: UserDefaults?
    private let key: String
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private var advertisement: Advertisement?
    private var selected: URL
    private var mode: HubConnectionMode
    private var generation = 0
    private var lastDiscovery = Date.distantPast
    private var lastProbe = Date.distantPast
    private var blockedUntil: [URL: Date] = [:]
    private var successes: [URL: Int] = [:]
    private var probeFailures = 0
    private var initialized = false
    private var flight: Task<URL, Error>?
    private var discoveryFlight: Task<Void, Never>?
    private var diagnosticsFlight: Task<Void, Never>?
    private var lastDiagnostics = Date.distantPast
    private var measurements: [URL: HubEndpointMeasurement] = [:]
    private var reason: HubConnectionDiagnostics.Reason = .starting {
        didSet { if reason != oldValue { reasonUpdatedAt = now() } }
    }
    private var reasonUpdatedAt: Date?
    private var activeGlobalStream: (id: UUID, origin: URL, route: HubConnectionRoute)?

    public init(canonicalURL: URL, performer: any HTTPPerforming = URLSessionHTTPPerformer.shared,
                persistent: Bool = true, now: @escaping @Sendable () -> Date = { Date() },
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.canonicalURL = canonicalURL; selected = canonicalURL
        self.performer = performer; self.now = now; self.uptime = uptime
        let defaults: UserDefaults? = persistent ? .standard : nil
        self.defaults = defaults
        key = "run.hapi.connection.\(canonicalURL.absoluteString)"
        advertisement = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Advertisement.self, from: $0) }
        mode = defaults?.string(forKey: key + ".mode").flatMap(HubConnectionMode.init(rawValue:)) ?? .automatic
    }

    private func route(_ origin: URL) -> HubConnectionRoute {
        if origin == canonicalURL { return .relay }
        return origin == advertisement?.lanUrl ? .lan : .tailscale
    }
    public func status() -> (mode: HubConnectionMode, isPrivate: Bool) { (mode, selected != canonicalURL) }
    public func diagnostics() -> HubConnectionDiagnostics {
        HubConnectionDiagnostics(mode: mode, isPrivate: selected != canonicalURL, reason: reason,
            privateMeasurement: advertisement?.privateUrl.flatMap { measurements[$0] }, publicMeasurement: measurements[canonicalURL],
            activeEventIsPrivate: activeGlobalStream.map { $0.origin != canonicalURL }, reasonUpdatedAt: reasonUpdatedAt,
            lanMeasurement: advertisement?.lanUrl.flatMap { measurements[$0] }, selectedRoute: mode == .automatic ? route(selected) : forcedOrigin().map(route) ?? route(selected),
            activeRoute: activeGlobalStream?.route, hasLAN: advertisement?.lanUrl != nil,
            hasTailscale: advertisement?.privateUrl != nil)
    }
    func eventStreamOpened(id: UUID, origin: URL) { activeGlobalStream = (id, origin, route(origin)) }
    func eventStreamClosed(id: UUID) { if activeGlobalStream?.id == id { activeGlobalStream = nil } }

    public func refreshDiagnostics(force: Bool = false) async {
        if let diagnosticsFlight { await diagnosticsFlight.value; return }
        guard force || now().timeIntervalSince(lastDiagnostics) >= 15 else { return }
        lastDiagnostics = now()
        let candidates = mode == .automatic
            ? [advertisement?.lanUrl, canonicalURL, force || selected == advertisement?.privateUrl ? advertisement?.privateUrl : nil].compactMap { $0 }
            : [forcedOrigin()].compactMap { $0 }
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for origin in candidates { group.addTask { _ = await self.probe(origin, timeout: 2) } }
            }
        }
        diagnosticsFlight = task
        await task.value
        if diagnosticsFlight == task { diagnosticsFlight = nil }
    }

    private func probe(_ origin: URL, timeout: TimeInterval) async -> Bool {
        guard Self.validOrigin(origin) else { return false }
        let expected = advertisement?.hubId
        let version = generation
        var request = URLRequest(url: origin.appendingPathComponent("health"))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let started = uptime()
        var outcome: HubEndpointMeasurement.Outcome = .unavailable
        var reused: Bool?
        do {
            let data: Data; let response: HTTPURLResponse
            if let performer = performer as? URLSessionHTTPPerformer {
                (data, response, reused) = try await performer.measuredProbe(request)
            } else { (data, response) = try await performer.perform(request) }
            struct Health: Decodable { let status: String; let hubId: String? }
            if response.url?.scheme != origin.scheme || response.url?.host != origin.host || response.url?.port != origin.port {
                outcome = .identityMismatch
            } else if response.statusCode != 200 { outcome = .httpError(response.statusCode) }
            else if let health = try? JSONDecoder().decode(Health.self, from: data), health.status == "ok" {
                if let expected, health.hubId == expected { outcome = .reachable }
                else if origin == canonicalURL && expected == nil { outcome = .reachable }
                else { outcome = .identityMismatch }
            }
        } catch { if (error as? URLError)?.code == .timedOut { outcome = .timeout } }
        guard version == generation, !Task.isCancelled else { return false }
        measurements[origin] = HubEndpointMeasurement(url: origin, checkedAt: now(), milliseconds: Int((uptime() - started) * 1000), outcome: outcome, reusedConnection: reused)
        return outcome == .reachable
    }

    public nonisolated static func forget(hubURL: String) {
        let origin = HubURLNormalization.normalize(hubURL) ?? hubURL
        let key = "run.hapi.connection.\(origin)"
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key + ".mode")
    }
    private func forcedOrigin() -> URL? {
        switch mode {
        case .automatic, .publicOnly: canonicalURL
        case .lanOnly: advertisement?.lanUrl
        case .privateOnly: advertisement?.privateUrl
        }
    }
    public func setMode(_ value: HubConnectionMode) {
        guard mode != value else { return }
        mode = value; defaults?.set(value.rawValue, forKey: key + ".mode")
        generation += 1
        flight?.cancel(); flight = nil
        discoveryFlight?.cancel(); discoveryFlight = nil
        lastProbe = .distantPast; initialized = false; successes = [:]; probeFailures = 0; blockedUntil = [:]
        selected = canonicalURL
        reason = value == .automatic ? .starting : value == .publicOnly ? .forcedPublic : value == .lanOnly ? .forcedLAN : .forcedPrivate
    }
    public func resolve(token: String? = nil) async throws -> URL {
        if mode == .publicOnly { return canonicalURL }
        if let flight { return try await flight.value }
        let task = Task { try await self.choose(token: token) }
        flight = task
        defer { if flight == task { flight = nil } }
        return try await task.value
    }
    func awaitBackgroundTasksForTesting() async { await discoveryFlight?.value }
    private func fetchAdvertisement(token: String) async -> Advertisement? {
        // A verified LAN can refresh discovery even when the relay is down.
        var request = URLRequest(url: selected.appendingPathComponent("v1/connection"))
        request.timeoutInterval = 2
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await performer.perform(request), response.statusCode == 200,
              let candidate = try? JSONDecoder().decode(Advertisement.self, from: data), !candidate.hubId.isEmpty,
              candidate.privateUrl.map(Self.validOrigin) ?? true, candidate.lanUrl.map(Self.validOrigin) ?? true,
              candidate.lanUrl == nil || candidate.lanUrl != candidate.privateUrl,
              candidate.lanUrl != canonicalURL, candidate.privateUrl != canonicalURL else { return nil }
        return candidate
    }
    private func applyAdvertisement(_ candidate: Advertisement) {
        if advertisement != candidate {
            generation += 1; selected = canonicalURL; lastProbe = .distantPast; initialized = false
            successes = [:]; probeFailures = 0; measurements = [:]; blockedUntil = [:]
        }
        advertisement = candidate
        if let data = try? JSONEncoder().encode(candidate) { defaults?.set(data, forKey: key) }
    }
    private func discover(token: String) async throws {
        if advertisement == nil {
            lastDiscovery = now()
            if let candidate = await fetchAdvertisement(token: token) { try Task.checkCancellation(); applyAdvertisement(candidate) }
        } else if initialized && now().timeIntervalSince(lastDiscovery) >= 300 && discoveryFlight == nil {
            lastDiscovery = now()
            let version = generation
            let task = Task {
                if let candidate = await self.fetchAdvertisement(token: token), !Task.isCancelled, version == self.generation {
                    self.applyAdvertisement(candidate)
                }
            }
            discoveryFlight = task
            Task { await task.value; if self.discoveryFlight == task { self.discoveryFlight = nil } }
        }
    }
    private func usable(_ origin: URL) -> Bool { now() >= (blockedUntil[origin] ?? .distantPast) }
    private func choose(token: String?) async throws -> URL {
        if let token { try await discover(token: token) }
        try Task.checkCancellation()
        if mode != .automatic {
            guard let origin = forcedOrigin() else { throw URLError(.cannotConnectToHost) }
            if !initialized || now().timeIntervalSince(lastProbe) >= 30 {
                lastProbe = now()
                let good = await probe(origin, timeout: 1)
                try Task.checkCancellation()
                guard good else { initialized = false; throw URLError(.cannotConnectToHost) }
                selected = origin; initialized = true
            }
            return selected
        }
        let wasInitialized = initialized
        let coolingLAN = advertisement?.lanUrl.flatMap { blockedUntil[$0] } != nil
        let interval: TimeInterval = probeFailures > 0 ? 10 : coolingLAN ? 15 : 30
        guard !initialized || now().timeIntervalSince(lastProbe) >= interval else { return selected }
        lastProbe = now()
        // LAN has a short budget. Tailscale is never probed before a healthy relay.
        if let lan = advertisement?.lanUrl, usable(lan) {
            blockedUntil[lan] = nil
            let good = await probe(lan, timeout: 0.35)
            try Task.checkCancellation()
            if good {
                successes[lan, default: 0] += 1
                if !wasInitialized || selected == lan || successes[lan, default: 0] >= 2 {
                    selected = lan; reason = .lanVerified; probeFailures = 0; initialized = true
                    return selected
                }
                reason = .awaitingRecovery
            } else {
                successes[lan] = 0
                if selected == lan {
                    probeFailures += 1
                    if wasInitialized && probeFailures < 2 { return selected }
                    selected = canonicalURL; reason = .privateUnavailable; probeFailures = 0
                }
            }
        }
        initialized = true
        if selected == advertisement?.privateUrl {
            let recovered = await probe(canonicalURL, timeout: 1)
            try Task.checkCancellation()
            successes[canonicalURL] = recovered ? successes[canonicalURL, default: 0] + 1 : 0
            if successes[canonicalURL, default: 0] >= 2 {
                selected = canonicalURL; blockedUntil[canonicalURL] = nil; reason = .publicPreferred
            }
            return selected
        }
        if usable(canonicalURL) {
            selected = canonicalURL
            if reason != .awaitingRecovery && reason != .privateUnavailable && reason != .privateNetworkFailure { reason = .publicPreferred }
            return selected
        }
        if let direct = advertisement?.privateUrl, usable(direct) {
            let good = await probe(direct, timeout: 1)
            try Task.checkCancellation()
            if good { selected = direct; reason = .tailscaleFallback; return selected }
        }
        // No healthy alternative; let the canonical request report the error.
        selected = canonicalURL; reason = .publicNetworkFailure
        return selected
    }
    public func failed(_ origin: URL) {
        guard origin == selected else { return }
        blockedUntil[origin] = now().addingTimeInterval(15)
        successes = [:]; probeFailures = 0; lastProbe = .distantPast
        initialized = true; selected = canonicalURL
        reason = origin == canonicalURL ? .publicNetworkFailure : .privateNetworkFailure
    }
    public func networkChanged() {
        generation += 1; flight?.cancel(); flight = nil
        lastProbe = .distantPast; blockedUntil = [:]; successes = [:]; probeFailures = 0
        initialized = false; selected = canonicalURL
    }
    private static func validOrigin(_ url: URL) -> Bool {
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
            let safe = request.httpMethod == "GET" || request.httpMethod == "HEAD" || request.url?.path == "/v1/auth/login"
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
    public init(router: HubConnectionRouter, underlying: any SSETransport = URLSessionSSETransport(), recheckInterval: Duration = .seconds(2)) {
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
                    if let origin, HubConnectionRouter.isNetworkFailure(error) { await router.failed(origin) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

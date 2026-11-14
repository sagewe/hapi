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
            if mode == .privateOnly { throw URLError(.cannotConnectToHost) }
            return canonicalURL
        }
        if reference >= failuresUntil && reference.timeIntervalSince(lastProbe) >= 30 {
            lastProbe = reference
            var request = URLRequest(url: direct.appendingPathComponent("health"))
            request.timeoutInterval = 1
            request.cachePolicy = .reloadIgnoringLocalCacheData
            struct Health: Decodable { let status: String; let hubId: String }
            let verified: Bool
            if let (data, response) = try? await performer.perform(request), response.statusCode == 200,
               let health = try? JSONDecoder().decode(Health.self, from: data) {
                verified = health.status == "ok" && health.hubId == advertisement.hubId
            } else { verified = false }
            try Task.checkCancellation()
            if verified {
                successes += 1
                if !initialized || selected == direct || successes >= 2 || mode == .privateOnly { selected = direct }
            } else {
                successes = 0; selected = canonicalURL
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
                do {
                    let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst(7)) }
                    let selected = try await router.resolve(token: token)
                    origin = selected
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await event in underlying.connect(router.rewrite(request, to: selected)) {
                                try Task.checkCancellation()
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
                    continuation.finish()
                } catch {
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

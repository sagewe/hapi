import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HubEndpointMeasurement: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case reachable, timeout, unavailable, identityMismatch, httpError(Int) }
    public let url: URL
    public let checkedAt: Date
    public let milliseconds: Int
    public let outcome: Outcome
    public let reusedConnection: Bool?

    public init(url: URL, checkedAt: Date, milliseconds: Int, outcome: Outcome, reusedConnection: Bool? = nil) {
        self.url = url; self.checkedAt = checkedAt; self.milliseconds = max(0, milliseconds)
        self.outcome = outcome; self.reusedConnection = reusedConnection
    }
}

public struct HubConnectionDiagnostics: Sendable {
    public enum Reason: Sendable, Equatable {
        case starting, privateVerified, privateUnavailable, awaitingRecovery, noPrivateEndpoint
        case forcedPublic, forcedPrivate, privateNetworkFailure, publicNetworkFailure
    }
    public let mode: HubConnectionMode
    public let isPrivate: Bool
    public let reason: Reason
    public let privateMeasurement: HubEndpointMeasurement?
    public let publicMeasurement: HubEndpointMeasurement?
    public let activeEventIsPrivate: Bool?
    public let reasonUpdatedAt: Date?
    public init(mode: HubConnectionMode, isPrivate: Bool, reason: Reason,
                privateMeasurement: HubEndpointMeasurement? = nil, publicMeasurement: HubEndpointMeasurement? = nil,
                activeEventIsPrivate: Bool? = nil, reasonUpdatedAt: Date? = nil) {
        self.mode = mode; self.isPrivate = isPrivate; self.reason = reason
        self.privateMeasurement = privateMeasurement; self.publicMeasurement = publicMeasurement
        self.activeEventIsPrivate = activeEventIsPrivate; self.reasonUpdatedAt = reasonUpdatedAt
    }
    public var currentMeasurement: HubEndpointMeasurement? {
        (activeEventIsPrivate ?? isPrivate) ? privateMeasurement : publicMeasurement
    }
}

#if !canImport(FoundationNetworking)
private final class ProbeMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var reused: Bool?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); defer { lock.unlock() }
        reused = metrics.transactionMetrics.last?.isReusedConnection
    }
    func connectionReuse() -> Bool? { lock.lock(); defer { lock.unlock() }; return reused }
}
#endif

extension URLSessionHTTPPerformer {
    /// Only health probes collect task metrics; ordinary requests are unchanged.
    func measuredProbe(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, Bool?) {
        #if canImport(FoundationNetworking)
        let (data, response) = try await perform(request)
        return (data, response, nil)
        #else
        let metrics = ProbeMetrics()
        let (data, response) = try await session.data(for: request, delegate: metrics)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response, metrics.connectionReuse())
        #endif
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HapiProtocol

/// Lifecycle & wire events yielded by ``SessionStreamClient``.
public enum SessionStreamClientEvent: Equatable, Sendable {
    case connected
    case disconnected
    case event(SessionStreamEvent)
}

/// Live token-streaming SSE client for `GET /v1/sessions/{id}/stream`.
///
/// Uses `Authorization: Bearer <jwt>` + `Accept: text/event-stream`, reconnects
/// with bounded exponential backoff, and tears down cleanly on `stop()` or
/// task cancellation.
public actor SessionStreamClient {
    private let baseURL: URL
    private let sessionId: String
    private let tokenProvider: @Sendable (Bool) async -> String?
    private let transport: any SSETransport
    private let clock: any SSEClock

    private var runTask: Task<Void, Never>?
    private var continuation: AsyncStream<SessionStreamClientEvent>.Continuation?
    private var stopped = false

    public init(
        baseURL: URL,
        sessionId: String,
        tokenProvider: @escaping @Sendable (_ forceRefresh: Bool) async -> String?,
        transport: any SSETransport,
        clock: any SSEClock = SystemSSEClock()
    ) {
        self.baseURL = baseURL
        self.sessionId = sessionId
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.clock = clock
    }

    public func start() -> AsyncStream<SessionStreamClientEvent> {
        let (stream, continuation) = AsyncStream<SessionStreamClientEvent>.makeStream()
        self.continuation = continuation
        guard !stopped else {
            continuation.finish()
            return stream
        }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
        return stream
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        runTask?.cancel()
        runTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func runLoop() async {
        var attempt = 0
        var forceRefreshToken = false

        while !stopped && !Task.isCancelled {
            guard let token = await tokenProvider(forceRefreshToken), !token.isEmpty else {
                forceRefreshToken = false
                let delayMs = backoffMs(attempt: attempt)
                attempt += 1
                do { try await clock.sleep(ms: delayMs) } catch { break }
                continue
            }
            forceRefreshToken = false

            guard let url = buildStreamURL() else { break }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            var didConnect = false
            var shouldForceRefresh = false
            var parser = SSELineParser()

            do {
                for try await item in transport.connect(request) {
                    if stopped || Task.isCancelled { break }
                    switch item {
                    case .connected(let response):
                        if response.statusCode == 401 {
                            shouldForceRefresh = true
                            break
                        }
                        guard (200..<300).contains(response.statusCode) else {
                            throw URLError(.badServerResponse)
                        }
                        didConnect = true
                        attempt = 0
                        continuation?.yield(.connected)
                    case .bytes(let data):
                        for frame in parser.consume(data) {
                            guard let payload = frame.data.data(using: .utf8),
                                  let event = try? HapiJSON.decoder.decode(SessionStreamEvent.self, from: payload) else {
                                continue
                            }
                            continuation?.yield(.event(event))
                        }
                    }
                    if shouldForceRefresh { break }
                }
            } catch is CancellationError {
                break
            } catch {
                // Fall through to reconnect with backoff.
            }

            if didConnect {
                continuation?.yield(.disconnected)
            }
            if stopped || Task.isCancelled { break }

            if shouldForceRefresh {
                forceRefreshToken = true
            }
            let delayMs = backoffMs(attempt: attempt)
            attempt += 1
            do { try await clock.sleep(ms: delayMs) } catch { break }
        }
    }

    private func buildStreamURL() -> URL? {
        let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.hasSuffix("/") == true
            ? String(components!.path.dropLast())
            : (components?.path ?? "")
        components?.path = "\(basePath)/v1/sessions/\(encoded)/stream"
        return components?.url
    }

    private func backoffMs(attempt: Int) -> Int {
        let seconds = min(15.0, pow(2.0, Double(min(attempt, 4))))
        return Int(seconds * 1000)
    }
}

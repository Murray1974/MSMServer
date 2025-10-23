import Vapor

/// Simple in-memory sliding-window rate limiter.
/// Keyed by a string (we’ll use client IP + path).
/// NOT distributed; restarts clear counters.
public struct RateLimitMiddleware: AsyncMiddleware {
    public enum Window: Sendable { case seconds(Int); var duration: Int { switch self { case .seconds(let s): return s } } }

    private let limit: Int
    private let window: Window
    private let identify: @Sendable (Request) -> String

    // ⬅️ Add this line:
    private static let store = RateStore()

    public init(limit: Int, window: Window, identify: @escaping @Sendable (Request) -> String) {
        self.limit = limit
        self.window = window
        self.identify = identify
    }

    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let key = identify(req)
        let allowed = await Self.store.checkAndRecord(
            key: key,
            limit: limit,
            windowSeconds: window.duration
        )
        if !allowed {
            let resp = Response(status: .tooManyRequests)
            resp.headers.replaceOrAdd(name: .retryAfter, value: String(window.duration))
            resp.body = .init(string: #"{"error":true,"reason":"Too many requests"}"#)
            resp.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
            return resp
        }
        return try await next.respond(to: req)
    }
}

/// Actor-protected store of timestamps.
actor RateStore {
    private var hits: [String: [TimeInterval]] = [:]

    /// Returns false if over limit (and records the new hit when allowed).
    func checkAndRecord(key: String, limit: Int, windowSeconds: Int) -> Bool {
        let now = Date().timeIntervalSince1970
        let windowStart = now - Double(windowSeconds)

        var arr = hits[key, default: []]
        // Drop hits outside the window
        arr = arr.filter { $0 >= windowStart }

        guard arr.count < limit else {
            hits[key] = arr // persist pruned array
            return false
        }

        arr.append(now)
        hits[key] = arr
        return true
    }
}


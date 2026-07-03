import Foundation

/// In-memory brute-force guard for POST /auth/login.
/// Tracks failed attempts per lowercase username.
/// After `maxAttempts` failures within `window` seconds the account is
/// locked for `lockout` seconds. A successful login clears the counter.
///
/// Thread-safe via Swift actor — safe to call from concurrent Vapor handlers.
actor LoginRateLimiter {

    static let shared = LoginRateLimiter()

    private let maxAttempts: Int       = 5
    private let window:      TimeInterval = 15 * 60   // 15 min rolling window
    private let lockout:     TimeInterval = 15 * 60   // 15 min lockout

    private struct Entry {
        var failCount:   Int
        var windowStart: Date
        var lockedUntil: Date?
    }

    private var store: [String: Entry] = [:]

    // MARK: - Public API

    /// Returns nil if the request is allowed, or a human-readable reason string if it is blocked.
    func check(username: String) -> String? {
        let key = username.lowercased()
        guard let entry = store[key] else { return nil }
        let now = Date()

        // Active lockout?
        if let locked = entry.lockedUntil, now < locked {
            let mins = max(1, Int(ceil(locked.timeIntervalSince(now) / 60)))
            return "Too many failed login attempts. Please try again in \(mins) minute\(mins == 1 ? "" : "s")."
        }

        // Expired window — reset silently.
        if now.timeIntervalSince(entry.windowStart) >= window {
            store.removeValue(forKey: key)
            return nil
        }

        return nil
    }

    func recordFailure(username: String) {
        let key = username.lowercased()
        let now = Date()
        var entry = store[key] ?? Entry(failCount: 0, windowStart: now, lockedUntil: nil)

        // Roll the window if expired.
        if now.timeIntervalSince(entry.windowStart) >= window {
            entry = Entry(failCount: 0, windowStart: now, lockedUntil: nil)
        }

        entry.failCount += 1

        if entry.failCount >= maxAttempts {
            entry.lockedUntil = now.addingTimeInterval(lockout)
        }

        store[key] = entry
    }

    func recordSuccess(username: String) {
        store.removeValue(forKey: username.lowercased())
    }
}

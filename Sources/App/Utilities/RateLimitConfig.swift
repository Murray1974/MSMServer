import Vapor

struct RateLimitConfig {
    let limit: Int
    let windowSeconds: Int

    static func fromEnv() -> RateLimitConfig {
        // Defaults match what you’ve been using
        let limit = Int(Environment.get("RATE_LIMIT_COUNT") ?? "") ?? 5
        let window = Int(Environment.get("RATE_LIMIT_WINDOW") ?? "") ?? 10
        return .init(limit: limit, windowSeconds: window)
    }
}

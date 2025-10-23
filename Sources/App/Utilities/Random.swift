import Foundation

enum Random {
    /// Returns a base64 token with `count` random bytes (default 32 = 256 bits).
    static func tokenBase64(count: Int = 32) -> String {
        let bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }
}

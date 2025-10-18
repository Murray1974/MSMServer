import Foundation

extension UserToken {
    static func generate(for user: User, lifetime: TimeInterval? = 60 * 60 * 24 * 7) throws -> UserToken {
        // Random 32-byte token
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        let tokenString = Data(buffer).base64EncodedString()

        let expiry = lifetime.map { Date().addingTimeInterval($0) }
        return try UserToken(value: tokenString, userID: user.requireID(), expiresAt: expiry)
    }
}

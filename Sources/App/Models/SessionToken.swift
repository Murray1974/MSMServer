import Vapor
import Fluent
import CryptoKit

/// Represents an opaque session token (like a bearer token).
/// The raw token is only shown once upon creation — only the hash is stored in the database.
final class SessionToken: Model {
    static let schema = "user_tokens"

    @ID(key: .id)
    var id: UUID?

    /// SHA256 hash of the raw token
    @Field(key: "token_hash")
    var tokenHash: String

    /// Optional expiry date
    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    /// Whether the token has been revoked
    @Field(key: "revoked")
    var revoked: Bool

    /// The associated user
    @Parent(key: "user_id")
    var user: User

    /// The raw token value (not stored in DB — only used when creating new tokens)
    var value: String?

    init() {}

    init(userID: UUID, tokenHash: String, expiresAt: Date? = nil, revoked: Bool = false) {
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
        self.revoked = revoked
    }

    // MARK: - Token Hashing Helper

    /// Hashes a raw token string using SHA256
    static func hash(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Token Generation

    /// Generates a new session token for the specified user.
    /// Returns a tuple containing (rawToken, modelInstance)
    static func generate(for user: User, ttl: TimeInterval? = nil) throws -> (String, SessionToken) {
        // Generate 32 random bytes
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let raw = Data(bytes).base64EncodedString()

        // Hash the token
        let hashed = Self.hash(raw)

        // Create a token model
        let token = SessionToken(userID: try user.requireID(), tokenHash: hashed)

        // Optional expiry
        if let ttl = ttl {
            token.expiresAt = Date().addingTimeInterval(ttl)
        }

        // Keep the raw token (so controller can return it once)
        token.value = raw
        return (raw, token)
    }
}

// MARK: - Fix for Sendable warning
extension SessionToken: @unchecked Sendable {}

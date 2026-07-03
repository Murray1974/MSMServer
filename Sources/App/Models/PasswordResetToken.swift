import Vapor
import Fluent

final class PasswordResetToken: Model, Content, @unchecked Sendable {
    static let schema = "password_reset_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// Bcrypt hash of the 6-digit OTP — never store the raw code.
    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    /// Marked true once used so it cannot be replayed.
    @Field(key: "used")
    var used: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(userID: UUID, codeHash: String, expiresAt: Date) {
        self.$user.id = userID
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.used = false
    }

    var isExpired: Bool { Date() > expiresAt }
}

import Vapor
import Fluent

/// Verifies an email address can receive mail *before* a student account is created,
/// catching typos (e.g. a mistyped inbox) at the point of entry rather than leaving an
/// account stuck with no reachable email for password recovery. Keyed by email directly
/// since no `User` exists yet at this stage.
final class EmailVerificationToken: Model, Content, @unchecked Sendable {
    static let schema = "email_verification_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    /// Bcrypt hash of the 6-digit OTP — never store the raw code.
    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "attempts")
    var attempts: Int

    @Field(key: "verified")
    var verified: Bool

    /// Bcrypt hash of the opaque ticket handed to the client once the code is verified.
    /// `/auth/register` must present the raw ticket to prove this email step was completed.
    @OptionalField(key: "ticket_hash")
    var ticketHash: String?

    @OptionalField(key: "consumed_at")
    var consumedAt: Date?

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(email: String, codeHash: String, expiresAt: Date) {
        self.email = email
        self.codeHash = codeHash
        self.attempts = 0
        self.verified = false
        self.expiresAt = expiresAt
    }

    var isExpired: Bool { Date() > expiresAt }
}

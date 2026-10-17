import Fluent

struct CreateEmailVerificationToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("email_verification_tokens")
            .id()
            .field("email", .string, .required)
            .field("code_hash", .string, .required)
            .field("attempts", .int, .required)
            .field("verified", .bool, .required)
            .field("ticket_hash", .string)
            .field("consumed_at", .datetime)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("email_verification_tokens").delete()
    }
}

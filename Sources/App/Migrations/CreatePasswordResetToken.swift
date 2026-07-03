import Fluent

struct CreatePasswordResetToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("password_reset_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used", .bool, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("password_reset_tokens").delete()
    }
}

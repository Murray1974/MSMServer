import Fluent

struct CreateSessionToken: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("user_tokens")
            .id()
            .field("token_hash", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("expires_at", .datetime)
            .field("revoked", .bool, .required, .sql(.default(false)))
            .unique(on: "token_hash")
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema("user_tokens").delete()
    }
}

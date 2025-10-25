import Fluent

struct CreateSessionToken: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("session_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime)
            .field("revoked", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema("session_tokens").delete()
    }
}

import Fluent

struct CreateUserToken: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(UserToken.schema)
            .id()
            .field("value", .string, .required)
            .unique(on: "value")
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("expires_at", .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(UserToken.schema).delete()
    }
}

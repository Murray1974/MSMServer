import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(User.schema)
            .id()
            .field("username", .string, .required)
            .unique(on: "username")
            .field("password_hash", .string, .required)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(User.schema).delete()
    }
}

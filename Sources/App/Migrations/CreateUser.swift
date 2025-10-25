import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("users")
            .id()
            .field("username", .string, .required)
            .field("password_hash", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "username")
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema("users").delete()
    }
}

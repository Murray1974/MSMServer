import Fluent

struct AddUniqueUsername: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("first_name", .string)
            .field("last_name", .string)
            .unique(on: "username")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("first_name")
            .deleteField("last_name")
            .deleteUnique(on: "username")
            .update()
    }
}

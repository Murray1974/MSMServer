import Fluent

struct AddUniqueUsername: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .unique(on: "username")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteUnique(on: "username")
            .update()
    }
}

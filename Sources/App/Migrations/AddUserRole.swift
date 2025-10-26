import Fluent

struct AddUserRole: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("users")
            .field("role", .string, .required, .sql(.default("student")))
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema("users")
            .deleteField("role")
            .update()
    }
}

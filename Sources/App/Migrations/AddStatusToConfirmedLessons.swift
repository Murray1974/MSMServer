import Fluent

struct AddStatusToConfirmedLessons: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("confirmed_lessons")
            .field("status", .string, .required, .sql(.default("attended")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("confirmed_lessons")
            .deleteField("status")
            .update()
    }
}

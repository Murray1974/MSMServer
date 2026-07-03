import Fluent

struct AddIsPrimaryToTestCentre: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_centres")
            .field("is_primary", .bool, .required, .custom("DEFAULT FALSE"))
            .update()
    }
    func revert(on database: Database) async throws {
        try await database.schema("test_centres")
            .deleteField("is_primary")
            .update()
    }
}

import Fluent

struct CreateTestCentre: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_centres")
            .id()
            .field("name",        .string,   .required)
            .field("known_times", .string,   .required)
            .field("updated_at",  .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_centres").delete()
    }
}

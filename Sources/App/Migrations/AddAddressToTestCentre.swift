import Fluent

struct AddAddressToTestCentre: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_centres")
            .field("address", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_centres")
            .deleteField("address")
            .update()
    }
}

import Fluent

struct CreateMileageEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("mileage_entries")
            .id()
            .field("date", .datetime, .required)
            .field("miles", .double, .required)
            .field("purpose", .string, .required)
            .field("from_location", .string)
            .field("to_location", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("mileage_entries").delete()
    }
}

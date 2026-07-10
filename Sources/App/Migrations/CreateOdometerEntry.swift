import Fluent

struct CreateOdometerEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("odometer_entries")
            .id()
            .field("date",         .datetime, .required)
            .field("odometer",     .double)
            .field("daily_miles",  .double,   .required)
            .field("is_gap_entry", .bool,     .required)
            .field("created_at",   .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("odometer_entries").delete()
    }
}

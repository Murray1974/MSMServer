import Fluent

struct CreateFuelEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("fuel_entries")
            .id()
            .field("date",                  .datetime, .required)
            .field("vendor",                .string,   .required)
            .field("total_cost",            .double,   .required)
            .field("pence_per_litre",       .double,   .required)
            .field("litres",                .double,   .required)
            .field("odometer_reading",      .double,   .required)
            .field("is_full_tank",          .bool,     .required)
            .field("miles_since_last_fill", .double)
            .field("mpg",                   .double)
            .field("cost_per_mile",         .double)
            .field("created_at",            .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("fuel_entries").delete()
    }
}

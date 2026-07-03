import Fluent

struct CreateVehicleLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vehicle_logs")
            .id()
            .field("instructor_id",        .uuid,     .required,
                   .references("users", "id", onDelete: .cascade))
            .field("log_date",             .datetime, .required)
            .field("odometer",             .int)
            .field("tyre_pressure_checked",.bool,     .required, .custom("DEFAULT FALSE"))
            .field("service_date",         .datetime)
            .field("fuel_litres",          .sql(raw: "NUMERIC(6,2)"))
            .field("notes",                .string)
            .field("created_at",           .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vehicle_logs").delete()
    }
}

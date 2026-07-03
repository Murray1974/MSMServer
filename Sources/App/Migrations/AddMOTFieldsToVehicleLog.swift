import Fluent

struct AddMOTFieldsToVehicleLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vehicle_logs")
            .field("last_mot_date",   .datetime)
            .field("mot_expiry_date", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vehicle_logs")
            .deleteField("last_mot_date")
            .deleteField("mot_expiry_date")
            .update()
    }
}

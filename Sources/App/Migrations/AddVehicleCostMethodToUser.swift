import Fluent

struct AddVehicleCostMethodToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("vehicle_cost_method", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("vehicle_cost_method")
            .update()
    }
}

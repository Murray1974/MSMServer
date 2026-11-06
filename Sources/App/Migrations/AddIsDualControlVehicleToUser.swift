import Fluent

struct AddIsDualControlVehicleToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("is_dual_control_vehicle", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("is_dual_control_vehicle")
            .update()
    }
}

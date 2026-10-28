import Fluent

struct AddContactAndVehicleFieldsToInstructorSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .field("contact_phone",       .string)
            .field("vehicle_registration", .string)
            .field("vehicle_make",        .string)
            .field("vehicle_model",       .string)
            .field("vehicle_colour",      .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .deleteField("contact_phone")
            .deleteField("vehicle_registration")
            .deleteField("vehicle_make")
            .deleteField("vehicle_model")
            .deleteField("vehicle_colour")
            .update()
    }
}

import Fluent

struct AddDefaultPickupLocationToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("default_pickup_location", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("default_pickup_location")
            .update()
    }
}

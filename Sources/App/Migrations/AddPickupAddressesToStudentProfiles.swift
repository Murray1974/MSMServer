import Fluent

struct AddPickupAddressesToStudentProfiles: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema("student_profiles")
            .field("pickup_home", .string)
            .field("pickup_work", .string)
            .field("pickup_college", .string)
            .field("pickup_school", .string)
            .update()
    }

    func revert(on db: Database) async throws {
        try await db.schema("student_profiles")
            .deleteField("pickup_home")
            .deleteField("pickup_work")
            .deleteField("pickup_college")
            .deleteField("pickup_school")
            .update()
    }
}

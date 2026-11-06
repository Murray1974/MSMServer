import Fluent

struct AddHomeLocationToInstructorSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .field("home_latitude", .double)
            .field("home_longitude", .double)
            .field("home_privacy_radius_metres", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .deleteField("home_latitude")
            .deleteField("home_longitude")
            .deleteField("home_privacy_radius_metres")
            .update()
    }
}

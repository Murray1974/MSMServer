import Fluent

struct CreateInstructorSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .id()
            .field("current_hourly_rate_pence", .int, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("instructor_settings").delete()
    }
}

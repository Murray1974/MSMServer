import Fluent

struct CreateTestAppointment: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_appointments")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("student_name", .string, .required)
            .field("test_time", .string, .required)
            .field("test_location", .string)
            .field("test_ref", .string, .required)
            .field("cancel_by_date", .string, .required)
            .field("starts_at", .datetime, .required)
            .field("ends_at", .datetime, .required)
            .field("state", .string, .required)
            .field("ek_event_id", .string)
            .field("charged_ledger_entry_id", .uuid, .references("ledger_entries", "id"))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_appointments").delete()
    }
}

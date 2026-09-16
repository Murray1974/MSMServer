import Fluent

struct AddInactivityFieldsToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("inactivity_stage14_sent_at", .datetime)
            .field("inactivity_stage21_sent_at", .datetime)
            .field("inactivity_auto_deactivated_at", .datetime)
            .field("first_lesson_confirmed_at", .datetime)
            .field("last_attended_lesson_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("inactivity_stage14_sent_at")
            .deleteField("inactivity_stage21_sent_at")
            .deleteField("inactivity_auto_deactivated_at")
            .deleteField("first_lesson_confirmed_at")
            .deleteField("last_attended_lesson_at")
            .update()
    }
}

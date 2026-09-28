import Fluent

struct AddTheoryReminderFieldToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("theory_reminder_dismissed_until", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("theory_reminder_dismissed_until")
            .update()
    }
}

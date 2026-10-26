import Fluent

struct AddTheoryExpiryWarningFieldToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("theory_expiry_warning_sent_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("theory_expiry_warning_sent_at")
            .update()
    }
}

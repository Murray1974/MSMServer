import Fluent

struct AddTheoryTestTimeToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("theory_test_time", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("theory_test_time")
            .update()
    }
}

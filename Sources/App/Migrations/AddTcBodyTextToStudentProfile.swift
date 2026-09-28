import Fluent

struct AddTcBodyTextToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("tc_body_text", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("tc_body_text")
            .update()
    }
}

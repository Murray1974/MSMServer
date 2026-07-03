import Fluent

struct AddDocumentFieldsToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("theory_test_passed", .bool, .required, .custom("DEFAULT FALSE"))
            .field("theory_test_date", .datetime)
            .field("licence_photo_path", .string)
            .field("licence_verified", .bool, .required, .custom("DEFAULT FALSE"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("theory_test_passed")
            .deleteField("theory_test_date")
            .deleteField("licence_photo_path")
            .deleteField("licence_verified")
            .update()
    }
}

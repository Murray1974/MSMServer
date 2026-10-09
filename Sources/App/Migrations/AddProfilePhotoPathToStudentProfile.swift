import Fluent

struct AddProfilePhotoPathToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("profile_photo_path", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("profile_photo_path")
            .update()
    }
}

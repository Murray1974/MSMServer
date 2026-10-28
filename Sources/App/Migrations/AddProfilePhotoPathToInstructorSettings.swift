import Fluent

struct AddProfilePhotoPathToInstructorSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .field("profile_photo_path", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .deleteField("profile_photo_path")
            .update()
    }
}

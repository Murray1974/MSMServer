import Fluent

struct AddAvatarEmojiToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("avatar_emoji", .string)
            .field("last_avatar_type", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("avatar_emoji")
            .deleteField("last_avatar_type")
            .update()
    }
}

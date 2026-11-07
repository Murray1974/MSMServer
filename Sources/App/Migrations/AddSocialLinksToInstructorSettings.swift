import Fluent

struct AddSocialLinksToInstructorSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .field("facebook_url", .string)
            .field("youtube_url", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("instructor_settings")
            .deleteField("facebook_url")
            .deleteField("youtube_url")
            .update()
    }
}

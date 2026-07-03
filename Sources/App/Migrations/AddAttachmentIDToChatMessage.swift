import Fluent

struct AddAttachmentIDToChatMessage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("chat_messages")
            .field("attachment_id", .uuid)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("chat_messages")
            .deleteField("attachment_id")
            .update()
    }
}

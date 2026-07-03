import Fluent

struct CreateChatAttachment: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("chat_attachments")
            .id()
            .field("data", .data, .required)
            .field("mime_type", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("chat_attachments").delete()
    }
}

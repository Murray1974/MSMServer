import Fluent

struct CreateChatMessage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("chat_messages")
            .id()
            .field("sender_id", .uuid, .required)
            .field("receiver_id", .uuid, .required)
            .field("content", .string, .required)
            .field("is_read", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("chat_messages").delete()
    }
}

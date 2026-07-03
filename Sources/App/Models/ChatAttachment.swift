import Fluent
import Vapor

final class ChatAttachment: Model, @unchecked Sendable {
    static let schema = "chat_attachments"

    @ID(key: .id) var id: UUID?
    @Field(key: "data") var data: Data
    @Field(key: "mime_type") var mimeType: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

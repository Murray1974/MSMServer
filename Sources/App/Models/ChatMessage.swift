import Fluent
import Vapor

final class ChatMessage: Model, Content, @unchecked Sendable {
    static let schema = "chat_messages"

    @ID(key: .id)
    var id: UUID?

    /// Raw UUID — stored directly to allow efficient OR-filter conversation queries.
    @Field(key: "sender_id")
    var senderID: UUID

    @Field(key: "receiver_id")
    var receiverID: UUID

    @Field(key: "content")
    var content: String

    @Field(key: "is_read")
    var isRead: Bool

    @OptionalField(key: "latitude")
    var latitude: Double?

    @OptionalField(key: "longitude")
    var longitude: Double?

    @OptionalField(key: "read_at")
    var readAt: Date?

    @OptionalField(key: "attachment_id")
    var attachmentID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, senderID: UUID, receiverID: UUID, content: String,
         isRead: Bool = false, latitude: Double? = nil, longitude: Double? = nil,
         attachmentID: UUID? = nil) {
        self.id = id
        self.senderID = senderID
        self.receiverID = receiverID
        self.content = content
        self.isRead = isRead
        self.latitude = latitude
        self.longitude = longitude
        self.attachmentID = attachmentID
    }
}

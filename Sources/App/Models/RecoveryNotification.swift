import Fluent
import Vapor

final class RecoveryNotification: Model, @unchecked Sendable {
    static let schema = "recovery_notifications"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "clients")
    var clients: [String]

    @Field(key: "message")
    var message: String

    @Timestamp(key: "seen_at", on: .none)
    var seenAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clients: [String],
        message: String,
        seenAt: Date? = nil
    ) {
        self.id = id
        self.clients = clients
        self.message = message
        self.seenAt = seenAt
    }
}

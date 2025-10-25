import Vapor
import Fluent

final class User: Model, Content {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "username")
    var username: String

    @Field(key: "password_hash")
    var passwordHash: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, username: String, passwordHash: String) {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
    }
}

// Use this in responses instead of sending the full model
extension User {
    struct Public: Content {
        let id: UUID?
        let username: String
        let createdAt: Date?
        let updatedAt: Date?
    }

    var asPublic: Public {
        .init(id: id, username: username, createdAt: createdAt, updatedAt: updatedAt)
    }
}

// Vapor auth
extension User: Authenticatable {}

// Swift 6 concurrency
extension User: @unchecked Sendable {}

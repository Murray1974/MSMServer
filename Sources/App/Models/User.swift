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

    // Simple role string: "student" | "instructor" | "admin"
    @Field(key: "role")
    var role: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, username: String, passwordHash: String, role: String = "student") {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
        self.role = role
    }
}

// Safe projection
extension User {
    struct Public: Content {
        let id: UUID?
        let username: String
        let role: String
        let createdAt: Date?
        let updatedAt: Date?
    }
    var asPublic: Public {
        .init(id: id, username: username, role: role, createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension User: Authenticatable {}
extension User: @unchecked Sendable {}

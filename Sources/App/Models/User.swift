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

    @OptionalField(key: "first_name")
    var firstName: String?

    @OptionalField(key: "last_name")
    var lastName: String?

    // Simple role string: "student" | "instructor" | "admin"
    @Field(key: "role")
    var role: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, username: String, passwordHash: String, firstName: String? = nil, lastName: String? = nil, role: String = "student") {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
        self.firstName = firstName
        self.lastName = lastName
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
        let firstName: String?
        let lastName: String?
        let displayName: String
    }

    var asPublic: Public {
        .init(id: id, username: username, role: role, createdAt: createdAt, updatedAt: updatedAt, firstName: firstName, lastName: lastName, displayName: displayName)
    }

    var displayName: String {
        let name = "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? username : name
    }
}

extension User: Authenticatable {}
extension User: @unchecked Sendable {}

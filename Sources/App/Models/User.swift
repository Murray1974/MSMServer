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

    @OptionalField(key: "fcm_token")
    var fcmToken: String?

    @OptionalField(key: "test_date")
    var testDate: Date?

    // Test auto-reject rules (instructor only)
    @Field(key: "test_auto_reject_clash")
    var testAutoRejectClash: Bool

    @Field(key: "test_min_weeks_enabled")
    var testMinWeeksEnabled: Bool

    @Field(key: "test_min_weeks")
    var testMinWeeks: Int

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
        if name.isEmpty == false {
            return name
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedUsername.isEmpty == false else { return username }

        if trimmedUsername.contains("-") || trimmedUsername.contains("_") {
            let normalized = trimmedUsername.replacingOccurrences(of: "_", with: "-")
            let humanized = normalized
                .split(separator: "-", omittingEmptySubsequences: true)
                .map { part in
                    let lower = part.lowercased()
                    return lower.prefix(1).uppercased() + lower.dropFirst()
                }
                .joined(separator: "-")

            return humanized.isEmpty ? trimmedUsername : humanized
        }

        return trimmedUsername
    }
}

extension User: Authenticatable {}
extension User: @unchecked Sendable {}

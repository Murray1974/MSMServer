import Vapor
import Fluent

final class UserToken: Model, Content {
    static let schema = "user_tokens"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "value")
    var value: String

    @Parent(key: "user_id")
    var user: User

    @Field(key: "expires_at")
    var expiresAt: Date?

    init() { }

    init(value: String, userID: UUID, expiresAt: Date? = nil) {
        self.value = value
        self.$user.id = userID
        self.expiresAt = expiresAt
    }
}

// This gives us `.authenticator()` and and ties the token to the user.
extension UserToken: ModelTokenAuthenticatable {
    static let valueKey = \UserToken.$value
    static let userKey = \UserToken.$user

    typealias User = App.User

    // Optional expiry support (deny if expired)
    var isValid: Bool {
        guard let expiresAt else { return true }
        return expiresAt > Date()
    }
}

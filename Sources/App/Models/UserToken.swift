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

    // Optional expiry. If you prefer OptionalField, that's fine too;
    // Timestamp keeps the db column typed as timestamptz if you want.
    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?

    init() {}

    init(id: UUID? = nil, value: String, userID: UUID, expiresAt: Date? = nil) {
        self.id = id
        self.value = value
        self.$user.id = userID
        self.expiresAt = expiresAt
    }
}

// MARK: - Token auth
extension UserToken: ModelTokenAuthenticatable {
    // IMPORTANT: disambiguate the associatedtype `User` using the module-qualified model type
    typealias User = App.User

    // Give the exact key-path types the protocol requires
    static var valueKey: KeyPath<UserToken, Field<String>> { \UserToken.$value }
    static var userKey:  KeyPath<UserToken, Parent<App.User>> { \UserToken.$user }

    var isValid: Bool {
        guard let exp = expiresAt else { return true }
        return exp > Date()
    }
}
// MARK: - Token generation helper
extension UserToken {
    static func generate(for user: User) throws -> UserToken {
        let value = Random.tokenBase64()   // 32-byte (256-bit) token, base64
        let expires = Date().addingTimeInterval(7 * 24 * 60 * 60) // 7 days
        return UserToken(
            value: value,
            userID: try user.requireID(),
            expiresAt: expires
        )
    }
}

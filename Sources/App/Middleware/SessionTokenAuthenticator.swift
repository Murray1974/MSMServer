import Vapor
import Fluent

/// Accepts `Authorization: Bearer <token>` and logs the user in if valid.
struct SessionTokenAuthenticator: AsyncBearerAuthenticator {
    typealias User = App.User

    func authenticate(bearer: BearerAuthorization, for req: Request) async throws {
        let hash = SessionToken.hash(bearer.token)

        // Find a non-revoked token with matching hash
        guard let token = try await SessionToken.query(on: req.db)
            .filter(\.$tokenHash == hash)
            .filter(\.$revoked == false)
            .first()
        else { return }

        // Expiry check (optional)
        if let exp = token.expiresAt, exp < Date() {
            token.revoked = true
            try await token.update(on: req.db)
            return
        }

        let user = try await token.$user.get(on: req.db)
        req.auth.login(user)
    }
}

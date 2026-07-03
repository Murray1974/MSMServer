import Vapor
import Fluent

/// Accepts `Authorization: Bearer <token>` and logs the user in if valid.
struct SessionTokenAuthenticator: AsyncBearerAuthenticator {
    typealias User = App.User

    func authenticate(bearer: BearerAuthorization, for req: Request) async throws {
        req.logger.info("[SessionTokenAuthenticator] Authorization header present: \(!req.headers[.authorization].isEmpty)")
        req.logger.info("[SessionTokenAuthenticator] Bearer token prefix: \(String(bearer.token.prefix(12)))")

        let hash = SessionToken.hash(bearer.token)
        req.logger.info("[SessionTokenAuthenticator] Token hash prefix: \(String(hash.prefix(12)))")

        guard let token = try await SessionToken.query(on: req.db)
            .filter(\.$tokenHash == hash)
            .filter(\.$revoked == false)
            .first()
        else {
            req.logger.warning("[SessionTokenAuthenticator] No matching non-revoked session token found")
            return
        }

        if let exp = token.expiresAt, exp < Date() {
            req.logger.warning("[SessionTokenAuthenticator] Token expired at \(exp)")
            token.revoked = true
            try await token.update(on: req.db)
            return
        }

        let user = try await token.$user.get(on: req.db)
        req.auth.login(user)
        req.logger.info("[SessionTokenAuthenticator] Authenticated user id: \(user.id?.uuidString ?? "nil")")
    }
}

import Vapor
import Fluent

// Request/Response DTOs
struct LoginRequest: Content {
    let username: String
    let password: String
}

struct LoginResponse: Content {
    let token: String
}

struct ChangePasswordRequest: Content {
    let currentPassword: String
    let newPassword: String
}

/// Authentication routes using opaque session tokens.
struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("login", use: login)

        // Protected
        let protected = auth.grouped(SessionTokenAuthenticator())
        protected.get("me", use: me)
        protected.post("logout", use: logout)
        protected.post("logout-all", use: logoutAll)
        protected.post("password", "change", use: changePassword)
    }

    // POST /auth/register -> 201
    func register(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(LoginRequest.self)

        // Unique username
        if try await User.query(on: req.db)
            .filter(\.$username == body.username)
            .first() != nil
        {
            throw Abort(.conflict, reason: "Username already exists.")
        }

        let hash = try await req.password.async.hash(body.password)
        let user = User(username: body.username, passwordHash: hash)
        try await user.save(on: req.db)
        return .created
    }

    // POST /auth/login -> { token }
    func login(req: Request) async throws -> LoginResponse {
        let body = try req.content.decode(LoginRequest.self)

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == body.username)
            .first()
        else { throw Abort(.unauthorized) }

        guard try await req.password.async.verify(body.password, created: user.passwordHash) else {
            throw Abort(.unauthorized)
        }

        let (raw, model) = try SessionToken.generate(for: user, ttl: 60 * 60) // 1 hour
        try await model.save(on: req.db)

        return .init(token: raw)
    }

    // GET /auth/me
    func me(req: Request) async throws -> User {
        return try req.auth.require(User.self)
    }

    // POST /auth/logout (invalidate JUST the presented token)
    func logout(req: Request) async throws -> HTTPStatus {
        _ = try req.auth.require(User.self) // ensure authenticated
        guard let bearer = req.headers.bearerAuthorization?.token else {
            throw Abort(.badRequest, reason: "Missing bearer token")
        }

        let hash = SessionToken.hash(bearer)

        try await SessionToken.query(on: req.db)
            .filter(\.$tokenHash == hash)
            .delete()

        return .noContent
    }

    // POST /auth/logout-all (invalidate ALL tokens for current user)
    func logoutAll(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let uid = try user.requireID()                 // <- compute first (fixes the 'try to the right' error)

        try await SessionToken.query(on: req.db)
            .filter(\.$user.$id == uid)
            .delete()

        return .noContent
    }

    // POST /auth/password/change
    func changePassword(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(ChangePasswordRequest.self)
        let user = try req.auth.require(User.self)

        guard try await req.password.async.verify(body.currentPassword, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Current password is incorrect")
        }

        user.passwordHash = try await req.password.async.hash(body.newPassword)
        try await user.save(on: req.db)

        // Revoke all tokens for this user (force re-login)
        let uid = try user.requireID()
        try await SessionToken.query(on: req.db)
            .filter(\.$user.$id == uid)
            .delete()

        return .noContent
    }
}

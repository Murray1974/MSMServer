import Vapor
import Fluent

// Body for /auth/login and /auth/register
struct LoginRequest: Content {
    let username: String
    let password: String
}

// Body for POST /auth/password/change
struct ChangePasswordRequest: Content {
    let currentPassword: String
    let newPassword: String
}

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Group under /auth
        let auth = routes.grouped("auth")

        // --- Public endpoints ---
        // Register a new user (201 on success, 409 if username taken)
        auth.post("register") { req async throws -> HTTPStatus in
            let body = try req.content.decode(LoginRequest.self)

            // ensure username is unique
            let exists = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first() != nil
            guard !exists else { throw Abort(.conflict, reason: "username is already taken") }

            let hash = try Bcrypt.hash(body.password)
            let user = User(username: body.username, passwordHash: hash)
            try await user.save(on: req.db)
            return .created
        }

        // Login -> returns a token (UserToken)
        auth.post("login") { req async throws -> UserToken in
            // 1) decode
            let body = try req.content.decode(LoginRequest.self)

            // 2) find user
            guard let user = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first()
            else { throw Abort(.unauthorized) }

            // 3) verify password
            let ok = try Bcrypt.verify(body.password, created: user.passwordHash)
            guard ok else { throw Abort(.unauthorized) }

            // 4) create token
            let token = try UserToken.generate(for: user)
            try await token.save(on: req.db)
            return token
        }

        // --- Protected endpoints (Bearer token required) ---
        let protected = routes.grouped(
            UserToken.authenticator(),   // resolves token from "Authorization: Bearer <token>"
            User.guardMiddleware()       // 401 if no user attached
        )

        // Who am I?
        protected.get("auth", "me") { req async throws -> User in
            try req.auth.require(User.self)
        }

        // Example protected API
        protected.get("auth", "secret") { req async throws -> String in
            _ = try req.auth.require(User.self)
            return "shhh"
        }

        // Logout: delete the current token (204)
        protected.post("auth", "logout") { req async throws -> HTTPStatus in
            _ = try req.auth.require(User.self)

            // Extract the *raw* bearer token string
            guard let bearer = req.headers.bearerAuthorization?.token else {
                throw Abort(.badRequest, reason: "Missing bearer token")
            }

            // Delete that token from DB
            try await UserToken.query(on: req.db)
                .filter(\.$value == bearer)
                .delete()

            return .noContent
        }
        
        // Change password (requires valid Bearer token)
        // - Verifies current password
        // - Updates to new password
        // - Revokes ALL existing tokens for this user
        // - Returns 204 No Content
        protected.post("auth","password", "change") { req async throws -> HTTPStatus in
            let body = try req.content.decode(ChangePasswordRequest.self)

            let user = try req.auth.require(User.self)

            let ok = try Bcrypt.verify(body.currentPassword, created: user.passwordHash)
            guard ok else {
                throw Abort(.unauthorized, reason: "Current password is incorrect")
            }

            user.passwordHash = try Bcrypt.hash(body.newPassword)
            try await user.save(on: req.db)

            try await UserToken
                .query(on: req.db)
                .filter(\.$user.$id == user.requireID())
                .delete()

            return .noContent
        }
    }
}

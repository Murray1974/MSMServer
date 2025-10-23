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
        // Group all authentication routes under /auth
        let auth = routes.grouped("auth")

        // ------------------------------------------------------------
        // // 🛡️  Rate Limiter setup
        // ------------------------------------------------------------
        let cfg = RateLimitConfig.fromEnv()

        let authLimiter = RateLimitMiddleware(
            limit: cfg.limit,
            window: .seconds(cfg.windowSeconds),
            identify: { req in
                // NOTE: clientIP is a property, not a function → no ()
                "\(req.clientIP)|\(req.url.path)"
            }
        )

        let publicAuth = auth.grouped(authLimiter)
        
        // ---- Public endpoints ----
        publicAuth.post("register") { req async throws -> HTTPStatus in
            let body = try req.content.decode(LoginRequest.self)
            let exists = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first() != nil
            guard !exists else { throw Abort(.conflict, reason: "username is already taken") }

            let hash = try Bcrypt.hash(body.password)
            let user = User(username: body.username, passwordHash: hash)
            try await user.save(on: req.db)
            return .created
        }

        publicAuth.post("login") { req async throws -> UserToken in
            let body = try req.content.decode(LoginRequest.self)
            guard let user = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first()
            else { throw Abort(.unauthorized) }

            guard try Bcrypt.verify(body.password, created: user.passwordHash)
            else { throw Abort(.unauthorized) }

            let token = try UserToken.generate(for: user)
            try await token.save(on: req.db)
            return token
        }

        // ---- Protected endpoints ----
        let protected = auth.grouped(
            UserToken.authenticator(),
            User.guardMiddleware()
        )

        protected.get("me") { req async throws -> User in
            try req.auth.require(User.self)
        }

        protected.get("secret") { req async throws -> String in
            _ = try req.auth.require(User.self)
            return "shhh"
        }

        // Logout current session
        protected.post("logout") { req async throws -> HTTPStatus in
            _ = try req.auth.require(User.self)
            guard let bearer = req.headers.bearerAuthorization?.token else {
                throw Abort(.badRequest, reason: "Missing bearer token")
            }

            try await UserToken.query(on: req.db)
                .filter(\.$value == bearer)
                .delete()

            return .noContent
        }

        // Logout all sessions for the current user
        protected.post("logout-all") { req async throws -> HTTPStatus in
            let user = try req.auth.require(User.self)

            try await UserToken.query(on: req.db)
                .filter(\.$user.$id == user.requireID())
                .delete()

            return .noContent
        }

        // Change password and revoke all tokens
        protected.post("password", "change") { req async throws -> HTTPStatus in
            let body = try req.content.decode(ChangePasswordRequest.self)
            let user = try req.auth.require(User.self)

            let ok = try Bcrypt.verify(body.currentPassword, created: user.passwordHash)
            guard ok else {
                throw Abort(.unauthorized, reason: "Current password is incorrect")
            }

            user.passwordHash = try Bcrypt.hash(body.newPassword)
            try await user.save(on: req.db)

            try await UserToken.query(on: req.db)
                .filter(\.$user.$id == user.requireID())
                .delete()

            return .noContent
        }
    }
    }


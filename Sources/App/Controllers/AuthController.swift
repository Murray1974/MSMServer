import Vapor
import Fluent

// Body for POST /auth/login
struct LoginRequest: Content {
    let username: String
    let password: String
}

// Body for POST /auth/register
struct RegisterRequest: Content {
    let username: String
    let password: String
}

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Group under /auth
        let auth = routes.grouped("auth")

        // MARK: - Register
        // Creates a new user (username must be unique, password is hashed)
        auth.post("register") { req async throws -> HTTPStatus in
            let body = try req.content.decode(RegisterRequest.self)

            // 1) Ensure username is available
            let existing = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first()
            guard existing == nil else {
                throw Abort(.conflict, reason: "Username is already taken.")
            }

            // 2) Hash password (bcrypt)
            let hash = try Bcrypt.hash(body.password)

            // 3) Save user
            let user = User(username: body.username, passwordHash: hash)
            try await user.save(on: req.db)

            return .created
        }

        // MARK: - Login -> returns token
        auth.post("login") { req async throws -> UserToken in
            // 1) Decode body
            let body = try req.content.decode(LoginRequest.self)

            // 2) Find user by username
            guard let user = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first()
            else { throw Abort(.unauthorized) }

            // 3) Verify password
            let ok = try Bcrypt.verify(body.password, created: user.passwordHash)
            guard ok else { throw Abort(.unauthorized) }

            // 4) Create & save token
            let token = try UserToken.generate(for: user)
            try await token.save(on: req.db)
            return token
        }

        // MARK: - Protected routes (Bearer token required)
        // Use the *auth* group so protected routes are under /auth/...
        let protected = auth.grouped(
            UserToken.authenticator(), // finds token and logs in the user
            User.guardMiddleware()     // 401 if no user in auth
        )

        // Current user
        protected.get("me") { req async throws -> User in
            try req.auth.require(User.self)
        }

        // Example protected API
        protected.get("secret") { req async throws -> String in
            _ = try req.auth.require(User.self)
            return "shhh"
        }

        // Logout: revoke the *current* token (from Authorization header)
        protected.post("logout") { req async throws -> HTTPStatus in
            // We only get the logged-in User from the authenticator; to revoke a
            // specific token we read the raw bearer token from the header.
            guard let bearer = req.headers.bearerAuthorization?.token else {
                throw Abort(.badRequest, reason: "Missing bearer token.")
            }

            try await UserToken.query(on: req.db)
                .filter(\.$value == bearer)
                .delete()

            return .noContent
        }
    }
}

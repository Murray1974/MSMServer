import Vapor
import Fluent

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("logout", use: logout)
    }

    // MARK: - DTOs
    struct Credentials: Content {
        let username: String
        let password: String
    }

    struct LoginResponse: Content {
        let token: String
    }

    // MARK: - Handlers

    /// POST /auth/register
    /// Creates a new user if the username is not taken.
    func register(_ req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(Credentials.self)

        // Ensure username uniqueness
        if let _ = try await User.query(on: req.db)
            .filter(\.$username == input.username)
            .first() {
            throw Abort(.conflict, reason: "Username already exists.")
        }

        // Create user with hashed password
        let hash = try Bcrypt.hash(input.password)
        let user = User(username: input.username, passwordHash: hash)
        try await user.save(on: req.db)

        return .created
    }

    /// POST /auth/login
    /// Verifies credentials, issues an opaque token, AND creates a server-side session (cookie).
    func login(_ req: Request) async throws -> LoginResponse {
        let input = try req.content.decode(Credentials.self)

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == input.username)
            .first() else {
            throw Abort(.unauthorized)
        }

        let ok = try Bcrypt.verify(input.password, created: user.passwordHash)
        guard ok else { throw Abort(.unauthorized) }

        // Issue opaque API token (unchanged behaviour if the project already uses tokens)
        let (raw, model) = try SessionToken.generate(for: user, ttl: 60 * 60) // 1 hour
        try await model.save(on: req.db)

        // ALSO create a server-side session so WebSocket & cookie-protected routes work
        let uid = try user.requireID()
        req.session.data["userID"] = uid.uuidString   // <-- Sets Set-Cookie: vapor-session=...

        return .init(token: raw)
    }

    /// POST /auth/logout
    /// Destroys the server-side session and (optionally) revokes tokens in future.
    func logout(_ req: Request) async throws -> HTTPStatus {
        req.session.destroy()
        return .noContent
    }
}

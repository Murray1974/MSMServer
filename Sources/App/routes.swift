import Vapor
import Fluent

struct LoginRequest: Content {
    let username: String
    let password: String
}

func routes(_ app: Application) throws {
    // Simple health check
    app.get { _ in "OK" }

    // Login → returns token
    app.post("login") { req async throws -> UserToken in
        let body = try req.content.decode(LoginRequest.self)

        // Find user
        guard let user = try await User.query(on: req.db)
            .filter(\.$username == body.username)
            .first()
        else { throw Abort(.unauthorized) }

        // Verify password
        let isValid = try Bcrypt.verify(body.password, created: user.passwordHash)
        guard isValid else { throw Abort(.unauthorized) }

        // Create token
        let token = try UserToken.generate(for: user)
        try await token.save(on: req.db)
        return token
    }

    // Protected routes: Bearer token header required
    let protected = app.grouped(
        UserToken.authenticator(),   // looks up token, sets req.auth.login(user)
        User.guardMiddleware()       // 401 if no User in auth
    )

    protected.get("me") { req async throws -> User in
        try req.auth.require(User.self)
    }

    // Example protected API
    protected.get("secret") { req async throws -> String in
        _ = try req.auth.require(User.self)
        return "shhh"
    }
}

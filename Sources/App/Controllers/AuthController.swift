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

        // POST /auth/login  -> returns a UserToken
        auth.post("login") { req async throws -> UserToken in
            // 1) decode body
            let body = try req.content.decode(LoginRequest.self)

            // 2) find user by username
            guard let user = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first()
            else { throw Abort(.unauthorized) }

            // 3) verify password
            let ok = try Bcrypt.verify(body.password, created: user.passwordHash)
            guard ok else { throw Abort(.unauthorized) }

            // 4) create and save token
            let token = try UserToken.generate(for: user)
            try await token.save(on: req.db)
            return token
        }
        
        // POST /auth/register -> create a new user
        auth.post("register") { req async throws -> HTTPStatus in
            let body = try req.content.decode(RegisterRequest.self)

            // 1) Check if username already exists
            if let _ = try await User.query(on: req.db)
                .filter(\.$username == body.username)
                .first() {
                throw Abort(.conflict, reason: "Username already taken")
            }

            // 2) Hash password
            let hash = try await req.password.async.hash(body.password)

            // 3) Save new user
            let user = User(username: body.username, passwordHash: hash)
            try await user.create(on: req.db)

            return .created
        }
        
        // Protected routes: requires a valid Bearer token
        let protected = routes.grouped(
            UserToken.authenticator(),   // finds token & logs in user
            User.guardMiddleware()       // 401 if no user in auth
        )

        protected.get("me") { req async throws -> User in
            try req.auth.require(User.self)
        }

        protected.get("secret") { req async throws -> String in
            _ = try req.auth.require(User.self)
            return "shhh"
        }
    }
}

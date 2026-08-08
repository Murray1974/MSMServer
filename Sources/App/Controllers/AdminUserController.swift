import Vapor
import Fluent

/// Instructor-only utility for creating plain staff-type accounts (e.g. a
/// family member who needs API access but isn't a student). Deliberately
/// separate from /auth/register, which is student self-signup and forces
/// driving-school-specific consent fields that don't apply here.
struct AdminUserController: RouteCollection {
    struct CreateUserRequest: Content {
        let username: String
        let password: String
        let role: String
        let firstName: String?
        let lastName: String?
    }

    private static let allowedRoles: Set<String> = ["student", "instructor", "admin", "family"]

    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware()).grouped("admin", "users")
        admin.post(use: create) // POST /admin/users
    }

    func create(_ req: Request) async throws -> User.Public {
        let caller = try req.auth.require(User.self)
        guard caller.role == "instructor" else {
            throw Abort(.forbidden)
        }

        let input = try req.content.decode(CreateUserRequest.self)
        let username = input.username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, username.contains("@") else {
            throw Abort(.unprocessableEntity, reason: "Please provide a valid email address.")
        }
        guard input.password.count >= 8 else {
            throw Abort(.unprocessableEntity, reason: "Password must be at least 8 characters.")
        }
        guard Self.allowedRoles.contains(input.role) else {
            throw Abort(.unprocessableEntity, reason: "Role must be one of: \(Self.allowedRoles.sorted().joined(separator: ", ")).")
        }

        if try await User.query(on: req.db).filter(\.$username == username).first() != nil {
            throw Abort(.conflict, reason: "An account with this email already exists.")
        }

        let hash = try Bcrypt.hash(input.password)
        let user = User(
            username: username,
            passwordHash: hash,
            firstName: input.firstName,
            lastName: input.lastName,
            role: input.role
        )
        try await user.save(on: req.db)

        req.logger.notice("[Admin] '\(caller.username)' created user '\(username)' with role '\(input.role)'")
        return user.asPublic
    }
}

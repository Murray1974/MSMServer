import Vapor

/// Single source of truth for password strength rules — called from every
/// endpoint that sets or changes a password (register, admin create, instructor
/// approve, forgot-password reset, change-password), so the rule only lives once.
struct PasswordPolicy {
    static func validate(_ password: String) throws {
        guard password.count >= 8 else {
            throw Abort(.unprocessableEntity, reason: "Password must be at least 8 characters.")
        }
        guard password.contains(where: { $0.isNumber }) else {
            throw Abort(.unprocessableEntity, reason: "Password must contain at least one number.")
        }
        guard password.contains(where: { !$0.isLetter && !$0.isNumber }) else {
            throw Abort(.unprocessableEntity, reason: "Password must contain at least one symbol.")
        }
    }
}

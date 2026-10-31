import Fluent
import FluentSQL

struct AddMustChangePasswordToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("must_change_password", .bool, .required, .custom("DEFAULT FALSE"))
            .update()

        // One-time backfill: every *existing* student account was set up with the same
        // shared starter password, so force a change on next login. Instructor/family
        // accounts chose their own password and aren't touched. New rows default to
        // false going forward — each creation path sets this explicitly for its own case
        // (see AdminUserController.create, InstructorPendingStudentsController.createStudentAccount).
        if let sql = database as? SQLDatabase {
            try await sql.raw("UPDATE users SET must_change_password = TRUE WHERE role = 'student'").run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("must_change_password")
            .update()
    }
}

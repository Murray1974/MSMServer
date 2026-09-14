import Fluent
import SQLKit
import Vapor

struct AddAccountStatusToStudentProfile: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS account_status TEXT NOT NULL DEFAULT 'active';").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS account_status;").run()
    }
}

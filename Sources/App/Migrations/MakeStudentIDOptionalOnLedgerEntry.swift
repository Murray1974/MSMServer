import Fluent
import SQLKit
import Vapor

struct MakeStudentIDOptionalOnLedgerEntry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }

        try await sql.raw("""
            ALTER TABLE ledger_entries
            ALTER COLUMN student_id DROP NOT NULL;
            """).run()
    }

    func revert(on database: any Database) async throws {
        // Only safe to re-add NOT NULL if no existing rows have student_id = NULL.
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }

        try await sql.raw("""
            ALTER TABLE ledger_entries
            ALTER COLUMN student_id SET NOT NULL;
            """).run()
    }
}

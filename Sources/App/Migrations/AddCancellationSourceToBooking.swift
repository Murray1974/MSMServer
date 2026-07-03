import Fluent
import SQLKit
import Vapor

struct AddCancellationSourceToBooking: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }
        try await sql.raw("""
            ALTER TABLE bookings
            ADD COLUMN IF NOT EXISTS cancellation_source TEXT;
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }
        try await sql.raw("""
            ALTER TABLE bookings
            DROP COLUMN IF EXISTS cancellation_source;
            """).run()
    }
}

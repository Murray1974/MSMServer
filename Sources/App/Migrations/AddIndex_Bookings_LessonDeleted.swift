import Fluent
import SQLKit

struct AddIndex_Bookings_LessonDeleted: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw(#"""
        CREATE INDEX IF NOT EXISTS idx_bookings_lesson_deleted
        ON "bookings" ("lesson_id", "deleted_at");
        """#).run()
    }
    func revert(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw(#"""
        DROP INDEX IF EXISTS idx_bookings_lesson_deleted;
        """#).run()
    }
}

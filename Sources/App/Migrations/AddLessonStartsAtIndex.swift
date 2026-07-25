import Fluent
import SQLKit

struct AddLessonStartsAtIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_lessons_starts_at ON lessons (starts_at)").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_lessons_starts_at").run()
    }
}

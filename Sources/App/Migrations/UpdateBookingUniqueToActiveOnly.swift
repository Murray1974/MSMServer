import Fluent
import SQLKit

struct UpdateBookingUniqueToActiveOnly: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }

        // Drop old unique constraint on (user_id, lesson_id)
        try await sql.raw(#"""
        ALTER TABLE "bookings"
        DROP CONSTRAINT IF EXISTS "uq:bookings.user_id+bookings.lesson_id";
        """#).run()

        // Create partial unique index for active (not soft-deleted) bookings
        try await sql.raw(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS uq_bookings_user_lesson_active
        ON "bookings" ("user_id", "lesson_id")
        WHERE deleted_at IS NULL;
        """#).run()
    }

    func revert(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw(#"""
        DROP INDEX IF EXISTS uq_bookings_user_lesson_active;
        """#).run()

        // (Optional) re-create the old constraint if you really want to revert:
        try await sql.raw(#"""
        ALTER TABLE "bookings"
        ADD CONSTRAINT "uq:bookings.user_id+bookings.lesson_id"
        UNIQUE ("user_id", "lesson_id");
        """#).run()
    }
}

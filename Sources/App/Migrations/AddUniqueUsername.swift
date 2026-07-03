import Fluent
import SQLKit

struct AddUniqueUsername: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        // Use IF NOT EXISTS so this is safe to run on a DB that already has these columns.
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS first_name TEXT").run()
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS last_name TEXT").run()
        // Add unique constraint only if it doesn't already exist.
        try await sql.raw("""
            DO $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conname = 'uq:users.username'
                  AND conrelid = 'users'::regclass
              ) THEN
                ALTER TABLE users ADD CONSTRAINT "uq:users.username" UNIQUE (username);
              END IF;
            END $$
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            DO $$
            BEGIN
              IF EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conname = 'uq:users.username'
                  AND conrelid = 'users'::regclass
              ) THEN
                ALTER TABLE users DROP CONSTRAINT "uq:users.username";
              END IF;
            END $$
            """).run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS first_name").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS last_name").run()
    }
}

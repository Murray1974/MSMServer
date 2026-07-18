import Fluent
import FluentSQL

// Raw SQL is intentional: Fluent's .required + .custom("DEFAULT ...") combination
// may generate ADD COLUMN NOT NULL and SET DEFAULT as two separate statements, which
// fails on a non-empty table. A single inline ADD COLUMN ... NOT NULL DEFAULT ... is
// the safe form. IF NOT EXISTS makes this idempotent if the migration partially ran.
struct AddRegistrationFieldsToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            ALTER TABLE student_profiles
            ADD COLUMN IF NOT EXISTS tc_accepted_at          TIMESTAMP,
            ADD COLUMN IF NOT EXISTS tc_version              TEXT,
            ADD COLUMN IF NOT EXISTS gdpr_consent_at         TIMESTAMP,
            ADD COLUMN IF NOT EXISTS dashcam_consent_at      TIMESTAMP,
            ADD COLUMN IF NOT EXISTS social_media_opt_in     BOOLEAN NOT NULL DEFAULT FALSE,
            ADD COLUMN IF NOT EXISTS eyesight_confirmed_at   TIMESTAMP,
            ADD COLUMN IF NOT EXISTS date_of_birth           TIMESTAMP,
            ADD COLUMN IF NOT EXISTS transmission_preference TEXT,
            ADD COLUMN IF NOT EXISTS previous_hours          INTEGER,
            ADD COLUMN IF NOT EXISTS approval_status         TEXT NOT NULL DEFAULT 'approved',
            ADD COLUMN IF NOT EXISTS approval_notes          TEXT
        """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! SQLDatabase
        try await sql.raw("""
            ALTER TABLE student_profiles
            DROP COLUMN IF EXISTS tc_accepted_at,
            DROP COLUMN IF EXISTS tc_version,
            DROP COLUMN IF EXISTS gdpr_consent_at,
            DROP COLUMN IF EXISTS dashcam_consent_at,
            DROP COLUMN IF EXISTS social_media_opt_in,
            DROP COLUMN IF EXISTS eyesight_confirmed_at,
            DROP COLUMN IF EXISTS date_of_birth,
            DROP COLUMN IF EXISTS transmission_preference,
            DROP COLUMN IF EXISTS previous_hours,
            DROP COLUMN IF EXISTS approval_status,
            DROP COLUMN IF EXISTS approval_notes
        """).run()
    }
}

import Fluent
import SQLKit
import Vapor

struct AddRegistrationFieldsToStudentProfile: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS tc_accepted_at TIMESTAMP;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS tc_version TEXT;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS gdpr_consent_at TIMESTAMP;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS dashcam_consent_at TIMESTAMP;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS social_media_opt_in BOOLEAN NOT NULL DEFAULT FALSE;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS eyesight_confirmed_at TIMESTAMP;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS date_of_birth TIMESTAMP;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS transmission_preference TEXT;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS previous_hours INTEGER;").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS approval_status TEXT NOT NULL DEFAULT 'approved';").run()
        try await sql.raw("ALTER TABLE student_profiles ADD COLUMN IF NOT EXISTS approval_notes TEXT;").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database does not support SQL migrations")
        }
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS tc_accepted_at;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS tc_version;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS gdpr_consent_at;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS dashcam_consent_at;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS social_media_opt_in;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS eyesight_confirmed_at;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS date_of_birth;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS transmission_preference;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS previous_hours;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS approval_status;").run()
        try await sql.raw("ALTER TABLE student_profiles DROP COLUMN IF EXISTS approval_notes;").run()
    }
}

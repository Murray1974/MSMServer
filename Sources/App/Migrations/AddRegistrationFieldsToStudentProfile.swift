import Fluent

struct AddRegistrationFieldsToStudentProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("student_profiles")
            .field("tc_accepted_at",          .datetime)
            .field("tc_version",              .string)
            .field("gdpr_consent_at",         .datetime)
            .field("dashcam_consent_at",      .datetime)
            .field("social_media_opt_in",     .bool,   .required, .custom("DEFAULT FALSE"))
            .field("eyesight_confirmed_at",   .datetime)
            .field("date_of_birth",           .datetime)
            .field("transmission_preference", .string)
            .field("previous_hours",          .int)
            .field("approval_status",         .string, .required, .custom("DEFAULT 'approved'"))
            .field("approval_notes",          .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("student_profiles")
            .deleteField("tc_accepted_at")
            .deleteField("tc_version")
            .deleteField("gdpr_consent_at")
            .deleteField("dashcam_consent_at")
            .deleteField("social_media_opt_in")
            .deleteField("eyesight_confirmed_at")
            .deleteField("date_of_birth")
            .deleteField("transmission_preference")
            .deleteField("previous_hours")
            .deleteField("approval_status")
            .deleteField("approval_notes")
            .update()
    }
}

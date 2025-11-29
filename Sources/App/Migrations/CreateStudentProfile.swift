//
//  CreateStudentProfile.swift
//  MSMServer
//
//  Created by Michael Murray on 17/11/2025.
//

import Fluent

/// Creates the `student_profiles` table used by `StudentProfile`.
struct CreateStudentProfile: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(StudentProfile.schema)
            .id()
            // Link back to the core users table.
            .field("user_id", .uuid, .required, .references(User.schema, "id"))

            // Basic identity
            .field("first_name", .string)
            .field("last_name", .string)
            .field("mobile", .string)
            .field("email", .string)

            // Address
            .field("address_line1", .string)
            .field("address_line2", .string)
            .field("city", .string)
            .field("postcode", .string)

            // Licence & theory
            .field("licence_type", .string)
            .field("provisional_licence_number", .string)
            .field("full_licence_number", .string)
            .field("licence_expiry_date", .datetime)
            .field("theory_certificate_number", .string)

            // Lesson defaults & rates
            .field("default_lesson_length_minutes", .int, .required)
            .field("hourly_rate_pence", .int, .required)

            // Safety / medical
            .field("eyesight_test_passed", .bool, .required)
            .field("medical_conditions", .string)

            // Timestamps
            .field("created_at", .datetime)
            .field("updated_at", .datetime)

            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(StudentProfile.schema).delete()
    }
}

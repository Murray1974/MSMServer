//
//  StudentProfile.swift
//  MSMServer
//
//  Created by Michael Murray on 17/11/2025.
//

import Vapor
import Fluent

/// Per-student profile data that extends the core `User` model.
/// This keeps authentication concerns (username/password) separate
/// from richer driving-lesson specific details.
final class StudentProfile: Model, Content, @unchecked Sendable {
    static let schema = "student_profiles"

    @ID(key: .id)
    var id: UUID?

    /// Owning user record. This links the profile to the login identity.
    @Parent(key: "user_id")
    var user: User

    // MARK: - Basic identity

    @OptionalField(key: "first_name")
    var firstName: String?

    @OptionalField(key: "last_name")
    var lastName: String?

    @OptionalField(key: "mobile")
    var mobile: String?

    @OptionalField(key: "email")
    var email: String?

    // MARK: - Address

    @OptionalField(key: "address_line1")
    var addressLine1: String?

    @OptionalField(key: "address_line2")
    var addressLine2: String?

    @OptionalField(key: "city")
    var city: String?

    @OptionalField(key: "postcode")
    var postcode: String?

    // MARK: - Saved pickup locations

    /// Optional saved pickup locations used by the student app.
    /// These are simple one-line descriptions like "Home", "Work",
    /// "Exeter College main entrance", etc.
    @OptionalField(key: "pickup_home")
    var pickupHome: String?

    @OptionalField(key: "pickup_work")
    var pickupWork: String?

    @OptionalField(key: "pickup_college")
    var pickupCollege: String?

    @OptionalField(key: "pickup_school")
    var pickupSchool: String?

    // MARK: - Licence & theory

    /// "learner" or "full" (can be extended later if needed).
    @OptionalField(key: "licence_type")
    var licenceType: String?

    @OptionalField(key: "provisional_licence_number")
    var provisionalLicenceNumber: String?

    @OptionalField(key: "full_licence_number")
    var fullLicenceNumber: String?

    @OptionalField(key: "licence_expiry_date")
    var licenceExpiryDate: Date?

    @OptionalField(key: "theory_certificate_number")
    var theoryCertificateNumber: String?

    // MARK: - Lesson defaults & rates

    /// Default lesson length in minutes (e.g. 120 for a 2‑hour slot).
    @Field(key: "default_lesson_length_minutes")
    var defaultLessonLengthMinutes: Int

    /// Hourly rate in pence (e.g. £45.00/hr = 4500).
    @Field(key: "hourly_rate_pence")
    var hourlyRatePence: Int

    // MARK: - Safety / medical

    /// Whether the eyesight test has been passed (at 20.5m number plate).
    @Field(key: "eyesight_test_passed")
    var eyesightTestPassed: Bool

    /// Free‑text field for relevant medical conditions (if applicable).
    @OptionalField(key: "medical_conditions")
    var medicalConditions: String?

    // MARK: - Timestamps

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // MARK: - Initialisers

    init() { }

    /// Convenience initialiser with sensible defaults for new profiles.
    init(
        id: UUID? = nil,
        userID: UUID,
        firstName: String? = nil,
        lastName: String? = nil,
        mobile: String? = nil,
        email: String? = nil,
        addressLine1: String? = nil,
        addressLine2: String? = nil,
        city: String? = nil,
        postcode: String? = nil,
        pickupHome: String? = nil,
        pickupWork: String? = nil,
        pickupCollege: String? = nil,
        pickupSchool: String? = nil,
        licenceType: String? = nil,
        provisionalLicenceNumber: String? = nil,
        fullLicenceNumber: String? = nil,
        licenceExpiryDate: Date? = nil,
        theoryCertificateNumber: String? = nil,
        defaultLessonLengthMinutes: Int = 120,
        hourlyRatePence: Int = 4500,
        eyesightTestPassed: Bool = false,
        medicalConditions: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.firstName = firstName
        self.lastName = lastName
        self.mobile = mobile
        self.email = email
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.city = city
        self.postcode = postcode
        self.pickupHome = pickupHome
        self.pickupWork = pickupWork
        self.pickupCollege = pickupCollege
        self.pickupSchool = pickupSchool
        self.licenceType = licenceType
        self.provisionalLicenceNumber = provisionalLicenceNumber
        self.fullLicenceNumber = fullLicenceNumber
        self.licenceExpiryDate = licenceExpiryDate
        self.theoryCertificateNumber = theoryCertificateNumber
        self.defaultLessonLengthMinutes = defaultLessonLengthMinutes
        self.hourlyRatePence = hourlyRatePence
        self.eyesightTestPassed = eyesightTestPassed
        self.medicalConditions = medicalConditions
    }
}

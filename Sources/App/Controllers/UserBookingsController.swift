import Vapor
import Fluent

struct MeProfileResponse: Content {
    struct ProfileDetails: Content {
        var firstName: String?
        var lastName: String?
        var mobile: String?
        var email: String?
        var addressLine1: String?
        var addressLine2: String?
        var city: String?
        var postcode: String?
        // Saved pickup locations
        var pickupHome: String?
        var pickupWork: String?
        var pickupCollege: String?
        var pickupSchool: String?
        var licenceType: String?
        var provisionalLicenceNumber: String?
        var fullLicenceNumber: String?
        var licenceExpiryDate: Date?
        var theoryCertificateNumber: String?
        var defaultLessonLengthMinutes: Int?
        var hourlyRatePence: Int?
        var eyesightTestPassed: Bool?
        var medicalConditions: String?
    }

    var id: UUID
    var username: String
    var profile: ProfileDetails?
}

struct UpdateProfileInput: Content {
    var firstName: String?
    var lastName: String?
    var mobile: String?
    var email: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var postcode: String?
    // Saved pickup locations
    var pickupHome: String?
    var pickupWork: String?
    var pickupCollege: String?
    var pickupSchool: String?
    var licenceType: String?
    var provisionalLicenceNumber: String?
    var fullLicenceNumber: String?
    var licenceExpiryDate: Date?
    var theoryCertificateNumber: String?
    var defaultLessonLengthMinutes: Int?
    var hourlyRatePence: Int?
    var eyesightTestPassed: Bool?
    var medicalConditions: String?
}

struct UserBookingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Protect with session-based auth: user must be logged in
        let me = routes
            .grouped(SessionTokenAuthenticator(), User.guardMiddleware())
            .grouped("me")

        // GET /me/profile
        me.get("profile", use: profile)

        // POST /me/profile/seed  (temporary helper to create a test profile row)
        me.post("profile", "seed", use: seedProfile)

        // PUT /me/profile  (create or update the student's profile)
        me.put("profile", use: updateProfile)

        // GET /me/bookings?scope=future|past|all
        me.get("bookings", use: listMyBookings)
    }

    // MARK: GET /me/profile
    func profile(_ req: Request) async throws -> MeProfileResponse {
        let user = try req.auth.require(User.self)
        let id = try user.requireID()

        // Look up any existing StudentProfile for this user.
        let profileModel = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == id)
            .first()

        let profilePayload: MeProfileResponse.ProfileDetails?
        if let p = profileModel {
            profilePayload = .init(
                firstName: p.firstName,
                lastName: p.lastName,
                mobile: p.mobile,
                email: p.email,
                addressLine1: p.addressLine1,
                addressLine2: p.addressLine2,
                city: p.city,
                postcode: p.postcode,
                pickupHome: p.pickupHome,
                pickupWork: p.pickupWork,
                pickupCollege: p.pickupCollege,
                pickupSchool: p.pickupSchool,
                licenceType: p.licenceType,
                provisionalLicenceNumber: p.provisionalLicenceNumber,
                fullLicenceNumber: p.fullLicenceNumber,
                licenceExpiryDate: p.licenceExpiryDate,
                theoryCertificateNumber: p.theoryCertificateNumber,
                defaultLessonLengthMinutes: p.defaultLessonLengthMinutes,
                hourlyRatePence: p.hourlyRatePence,
                eyesightTestPassed: p.eyesightTestPassed,
                medicalConditions: p.medicalConditions
            )
        } else {
            profilePayload = nil
        }

        return MeProfileResponse(
            id: id,
            username: user.username,
            profile: profilePayload
        )
    }

    struct MyBookingRow: Content {
        var bookingID: UUID
        var lessonID: UUID
        var title: String?
        var startsAt: Date?
        var endsAt: Date?
        var status: String
    }

    func listMyBookings(_ req: Request) async throws -> [MyBookingRow] {
        // 1) who is calling?
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        // 2) optional filter
        let scope = (try? req.query.get(String.self, at: "scope")) ?? "future"
        let now = Date()

        // 3) load this user's bookings (+ lesson)
        let bookings = try await Booking.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$deletedAt == nil)   // ignore soft-deleted bookings
            .with(\.$lesson)
            .all()

        // 4) apply scope, using per-booking override where available
        let filtered: [Booking]
        switch scope {
        case "past":
            filtered = bookings.filter { booking in
                let lesson = booking.lesson
                let ends = booking.actualEndsAt ?? lesson.endsAt
                return ends < now
            }

        case "all":
            filtered = bookings

        default: // "future"
            filtered = bookings.filter { booking in
                let lesson = booking.lesson
                let ends = booking.actualEndsAt ?? lesson.endsAt
                return ends >= now
            }
        }

        // 5) map to response rows
        return filtered.compactMap { booking in
            let lesson = booking.lesson
            guard let bookingID = booking.id,
                  let lessonID = lesson.id else {
                return nil
            }
            let ends = booking.actualEndsAt ?? lesson.endsAt
            return MyBookingRow(
                bookingID: bookingID,
                lessonID: lessonID,
                title: lesson.title,
                startsAt: lesson.startsAt,
                endsAt: ends,
                status: "active"
            )
        }
    }

    // MARK: PUT /me/profile
    /// Creates or updates the StudentProfile for the logged-in user.
    func updateProfile(_ req: Request) async throws -> MeProfileResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let input = try req.content.decode(UpdateProfileInput.self)

        // Look up existing profile, if any.
        let existing = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()

        let profileModel: StudentProfile
        if let current = existing {
            // Update only fields that were provided (non-nil in input).
            if let v = input.firstName { current.firstName = v }
            if let v = input.lastName { current.lastName = v }
            if let v = input.mobile { current.mobile = v }
            if let v = input.email { current.email = v }
            if let v = input.addressLine1 { current.addressLine1 = v }
            if let v = input.addressLine2 { current.addressLine2 = v }
            if let v = input.city { current.city = v }
            if let v = input.postcode { current.postcode = v }
            if let v = input.pickupHome { current.pickupHome = v }
            if let v = input.pickupWork { current.pickupWork = v }
            if let v = input.pickupCollege { current.pickupCollege = v }
            if let v = input.pickupSchool { current.pickupSchool = v }
            if let v = input.licenceType { current.licenceType = v }
            if let v = input.provisionalLicenceNumber { current.provisionalLicenceNumber = v }
            if let v = input.fullLicenceNumber { current.fullLicenceNumber = v }
            if let v = input.licenceExpiryDate { current.licenceExpiryDate = v }
            if let v = input.theoryCertificateNumber { current.theoryCertificateNumber = v }
            if let v = input.defaultLessonLengthMinutes { current.defaultLessonLengthMinutes = v }
            if let v = input.hourlyRatePence { current.hourlyRatePence = v }
            if let v = input.eyesightTestPassed { current.eyesightTestPassed = v }
            if let v = input.medicalConditions { current.medicalConditions = v }

            profileModel = current
        } else {
            // Create a new profile with sensible defaults, overriding with any provided fields.
            profileModel = StudentProfile(
                userID: userID,
                firstName: input.firstName,
                lastName: input.lastName,
                mobile: input.mobile,
                email: input.email,
                addressLine1: input.addressLine1,
                addressLine2: input.addressLine2,
                city: input.city,
                postcode: input.postcode,
                pickupHome: input.pickupHome,
                pickupWork: input.pickupWork,
                pickupCollege: input.pickupCollege,
                pickupSchool: input.pickupSchool,
                licenceType: input.licenceType,
                provisionalLicenceNumber: input.provisionalLicenceNumber,
                fullLicenceNumber: input.fullLicenceNumber,
                licenceExpiryDate: input.licenceExpiryDate,
                theoryCertificateNumber: input.theoryCertificateNumber,
                defaultLessonLengthMinutes: input.defaultLessonLengthMinutes ?? 120,
                hourlyRatePence: input.hourlyRatePence ?? 4500,
                eyesightTestPassed: input.eyesightTestPassed ?? false,
                medicalConditions: input.medicalConditions
            )
        }

        try await profileModel.save(on: req.db)

        // Return the standard /me/profile payload.
        return try await profile(req)
    }

    // MARK: POST /me/profile/seed
    /// Temporary helper: creates a simple StudentProfile for the logged-in user
    /// so that /me/profile returns a non-nil profile block.
    func seedProfile(_ req: Request) async throws -> MeProfileResponse {
        let user = try req.auth.require(User.self)
        let id = try user.requireID()
  
        // If a profile already exists, just return the normal /me/profile payload.
        if let _ = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == id)
            .first()
        {
            return try await profile(req)
        }
  
        // Create a basic starter profile for testing.
        let newProfile = StudentProfile(
            userID: id,
            firstName: "Michael",
            lastName: "Murray",
            mobile: "07000000000",
            email: "test@example.com",
            defaultLessonLengthMinutes: 120,
            hourlyRatePence: 4500,
            eyesightTestPassed: false
        )
  
        try await newProfile.save(on: req.db)
        return try await profile(req)
    }
}

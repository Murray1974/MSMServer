import Fluent
import Vapor

/// `AuthController.register` and `InstructorPendingStudentsController.createStudentAccount`
/// both save the `User` row and its `StudentProfile` as two separate, non-transactional
/// writes. If anything failed between the two (a mid-request crash, the 17 Oct disk-full
/// outage, etc.) the `User` row survives with no `StudentProfile` — confirmed in production:
/// 13 real student accounts (Oliver Forster, Courtney Fox, Stephanie German, Jake Gough,
/// Luke Harmer, Estelle Harris, Nicole Knutton, Dan Meredith, Benjy Mungall, Harrison
/// Pantling, Eve Parsons, Jasmine Stansfield, Vihaan Tahilyani) have no `StudentProfile`,
/// which silently breaks anything reading from it — e.g. `AddPaymentSheet`'s quick-amount
/// buttons (gated on `hourlyRateGBP`, sourced from `StudentProfile.hourlyRatePence`) and
/// the pickup-address default used by `TrackingService`/journey recording when a booking
/// has no explicit pickup address of its own. Both creation paths are now wrapped in a DB
/// transaction (see those files) so this can't recur; this is a one-time repair for the
/// accounts already affected.
struct BackfillMissingStudentProfiles: AsyncMigration {
    func prepare(on database: Database) async throws {
        let students = try await User.query(on: database)
            .filter(\.$role == "student")
            .all()

        let defaultRatePence = try await InstructorSettings.currentRatePence(on: database)

        for student in students {
            guard let userID = student.id else { continue }
            let existing = try await StudentProfile.query(on: database)
                .filter(\.$user.$id == userID)
                .first()
            guard existing == nil else { continue }

            let profile = StudentProfile(
                userID: userID,
                firstName: student.firstName,
                lastName: student.lastName,
                email: student.username,
                hourlyRatePence: defaultRatePence
            )
            try await profile.save(on: database)
            database.logger.notice("[Backfill] Created missing StudentProfile for userID=\(userID) username=\(student.username)")
        }
    }

    func revert(on database: Database) async throws {
        // No-op — a backfilled profile may since have real student data on it
        // (pickup addresses, licence details, etc.), so there's no safe automatic revert.
    }
}

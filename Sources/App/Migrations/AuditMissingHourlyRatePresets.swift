import Fluent
import Vapor

/// One-time, read-only diagnostic — logs the account/profile state for the named students
/// whose Instructor app "Add Payment" sheet isn't showing the 1hr/1.5hr/2hr preset
/// buttons, even after `BackfillMissingStudentProfiles` ran. That migration only found 3
/// accounts (applereview@, benpmungall@gmail.com, eveparsons239@gmail.com) genuinely
/// missing a `StudentProfile` row, so the other ~10 named students must have a profile
/// already — this checks for duplicate `User` rows for the same person (one with
/// booking/finance history, another with the profile) as the likely alternative
/// explanation, by logging every User row matching each target name plus whether each
/// has a StudentProfile.
struct AuditMissingHourlyRatePresets: AsyncMigration {
    func prepare(on database: Database) async throws {
        let targets = [
            "Oliver Forster", "Courtney Fox", "Stephanie German", "Jake Gough",
            "Luke Harmer", "Estelle Harris", "Nicole Knutton", "Dan Meredith",
            "Benjy Mungall", "Harrison Pantling", "Eve Parsons", "Jasmine Stansfield",
            "Vihaan Tahilyani"
        ]

        for fullName in targets {
            let parts = fullName.split(separator: " ")
            guard let first = parts.first else { continue }
            let last = parts.dropFirst().joined(separator: " ")

            let matches = try await User.query(on: database)
                .filter(\.$role == "student")
                .group(.or) { g in
                    g.filter(\.$firstName == String(first))
                    g.group(.and) { g2 in
                        g2.filter(\.$firstName == String(first))
                        g2.filter(\.$lastName == last)
                    }
                }
                .all()

            if matches.isEmpty {
                database.logger.notice("[Audit] '\(fullName)': no matching User row at all")
                continue
            }

            for user in matches {
                guard let userID = user.id else { continue }
                let profile = try await StudentProfile.query(on: database)
                    .filter(\.$user.$id == userID)
                    .first()
                let bookingCount = try await Booking.query(on: database)
                    .filter(\.$user.$id == userID)
                    .filter(\.$deletedAt == .null)
                    .count()
                database.logger.notice(
                    "[Audit] '\(fullName)' userID=\(userID) username=\(user.username) hasProfile=\(profile != nil) hourlyRatePence=\(profile?.hourlyRatePence.description ?? "nil") activeBookings=\(bookingCount)"
                )
            }
        }
    }

    func revert(on database: Database) async throws {}
}

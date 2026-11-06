import Fluent
import Vapor

/// Follow-up to `AuditMissingHourlyRatePresets` — that migration found no `User` row for
/// "Dan Meredith", but the actual registered name is "Daniel Meredith". Logs every student
/// User row with firstName containing "Dan" (covers "Dan" and "Daniel") to find the real
/// account and check its StudentProfile/rate.
struct AuditDanielMeredith: AsyncMigration {
    func prepare(on database: Database) async throws {
        let matches = try await User.query(on: database)
            .filter(\.$role == "student")
            .group(.or) { g in
                g.filter(\.$firstName ~~ "Dan")
                g.filter(\.$lastName ~~ "Meredith")
            }
            .all()

        if matches.isEmpty {
            database.logger.notice("[AuditDaniel] no User row matching 'Dan*' or '*Meredith*'")
            return
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
                "[AuditDaniel] firstName=\(user.firstName) lastName=\(user.lastName ?? "nil") userID=\(userID) username=\(user.username) hasProfile=\(profile != nil) hourlyRatePence=\(profile?.hourlyRatePence.description ?? "nil") activeBookings=\(bookingCount)"
            )
        }
    }

    func revert(on database: Database) async throws {}
}

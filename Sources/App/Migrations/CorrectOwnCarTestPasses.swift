import Fluent
import Vapor

/// Follow-up to `CorrectStudentStatusMisclassifications`, which flipped Kody Taylor and Erin
/// Le-Leivre to inactive with reason "permanent" (grouped with the other genuine losses at
/// the time). The instructor clarified afterwards: both actually passed their test, just in
/// their own car rather than the instructor's — a real completion, not a loss, but one that
/// shouldn't count toward the instructor's own-car pass-rate metric. Corrects their most
/// recent inactive-transition event's reason to "passed_test_own_car" (see
/// `StudentMetricsService.completionReasons`).
struct CorrectOwnCarTestPasses: AsyncMigration {
    func prepare(on database: Database) async throws {
        let names = ["Kody Taylor", "Erin Le-Leivre"]

        for fullName in names {
            let parts = fullName.split(separator: " ")
            guard let first = parts.first else { continue }
            let last = parts.dropFirst().joined(separator: " ")

            guard let user = try await User.query(on: database)
                .filter(\.$role == "student")
                .filter(\.$firstName == String(first))
                .filter(\.$lastName == last)
                .first(),
                let userID = user.id
            else {
                database.logger.notice("[CorrectOwnCar] '\(fullName)': no matching User row — skipped")
                continue
            }

            guard let latestEvent = try await StudentStatusEvent.query(on: database)
                .filter(\.$student.$id == userID)
                .filter(\.$toStatus == "inactive")
                .sort(\.$occurredAt, .descending)
                .first()
            else {
                let event = StudentStatusEvent(
                    studentID: userID,
                    fromStatus: "active",
                    toStatus: "inactive",
                    reason: "passed_test_own_car"
                )
                try await event.save(on: database)
                database.logger.notice("[CorrectOwnCar] '\(fullName)': no existing event — created passed_test_own_car event")
                continue
            }

            latestEvent.reason = "passed_test_own_car"
            try await latestEvent.save(on: database)
            database.logger.notice("[CorrectOwnCar] '\(fullName)': corrected reason -> passed_test_own_car")
        }
    }

    func revert(on database: Database) async throws {}
}

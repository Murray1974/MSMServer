import Fluent
import Vapor

/// One-time correction, confirmed directly by the instructor against the live roster dump
/// from `ListAllStudentNamesAndStatus`:
///
/// - Group A — shown "active" but actually passed their test and should be archived as a
///   completion: Jayden Elliott, Kacey Hill, Autumn Avery, Kaitlyn Aurora, Molly Hoddinott,
///   Kelvin Nickles. Flips accountStatus to inactive and logs a passed_test StudentStatusEvent.
/// - Group B — already correctly inactive, but the archive reason on file is wrong (not
///   tagged as a test pass): Ellie Prince, Finnley Hancock, Zoe Squire, Karen Insignares,
///   Harvey Baker, Eloise Styles, Tyler Strong. Corrects the most recent inactive-transition
///   event's reason to passed_test (creates one retroactively if none exists — needed so
///   `StudentMetricsService`'s turnover/retention counts these as completions, not losses).
/// - Group C — shown "active" but are genuinely no longer current clients, not test passes:
///   Chelsea Weeks, Ruth Dumbreck, Kody Taylor, Callum Stevens, Erin Le-Leivre, Jake Gough.
///   Flips accountStatus to inactive with reason "permanent" (sensible default — can be
///   switched to "temporary" per-client afterwards if the instructor wants).
struct CorrectStudentStatusMisclassifications: AsyncMigration {
    func prepare(on database: Database) async throws {
        let passedTestNowActive = [
            "Jayden Elliott", "Kacey Hill", "Autumn Avery",
            "Kaitlyn Aurora", "Molly Hoddinott", "Kelvin Nickles"
        ]
        let passedTestAlreadyInactive = [
            "Ellie Prince", "Finnley Hancock", "Zoe Squire", "Karen Insignares",
            "Harvey Baker", "Eloise Styles", "Tyler Strong"
        ]
        let genuineArchiveNowActive = [
            "Chelsea Weeks", "Ruth Dumbreck", "Kody Taylor",
            "Callum Stevens", "Erin Le-Leivre", "Jake Gough"
        ]

        func findUser(_ fullName: String) async throws -> User? {
            let parts = fullName.split(separator: " ")
            guard let first = parts.first else { return nil }
            let last = parts.dropFirst().joined(separator: " ")
            return try await User.query(on: database)
                .filter(\.$role == "student")
                .filter(\.$firstName == String(first))
                .filter(\.$lastName == last)
                .first()
        }

        // Group A + C — flip active -> inactive with the given reason
        func flipToInactive(_ fullName: String, reason: String) async throws {
            guard let user = try await findUser(fullName), let userID = user.id else {
                database.logger.notice("[Correct] '\(fullName)': no matching User row — skipped")
                return
            }
            guard let profile = try await StudentProfile.query(on: database)
                .filter(\.$user.$id == userID)
                .first()
            else {
                database.logger.notice("[Correct] '\(fullName)': no StudentProfile — skipped")
                return
            }
            let previousStatus = profile.accountStatus
            guard previousStatus != "inactive" else {
                database.logger.notice("[Correct] '\(fullName)': already inactive — skipped status flip")
                return
            }
            profile.accountStatus = "inactive"
            try await profile.save(on: database)
            let event = StudentStatusEvent(
                studentID: userID,
                fromStatus: previousStatus,
                toStatus: "inactive",
                reason: reason
            )
            try await event.save(on: database)
            database.logger.notice("[Correct] '\(fullName)': active -> inactive, reason=\(reason)")
        }

        // Group B — already inactive, correct the reason on the most recent transition event
        func correctReason(_ fullName: String) async throws {
            guard let user = try await findUser(fullName), let userID = user.id else {
                database.logger.notice("[Correct] '\(fullName)': no matching User row — skipped")
                return
            }
            let latestEvent = try await StudentStatusEvent.query(on: database)
                .filter(\.$student.$id == userID)
                .filter(\.$toStatus == "inactive")
                .sort(\.$occurredAt, .descending)
                .first()

            if let latestEvent {
                latestEvent.reason = "passed_test"
                try await latestEvent.save(on: database)
                database.logger.notice("[Correct] '\(fullName)': corrected existing event reason -> passed_test")
            } else {
                let event = StudentStatusEvent(
                    studentID: userID,
                    fromStatus: "active",
                    toStatus: "inactive",
                    reason: "passed_test"
                )
                try await event.save(on: database)
                database.logger.notice("[Correct] '\(fullName)': no existing event found — created retroactive passed_test event")
            }
        }

        for name in passedTestNowActive {
            try await flipToInactive(name, reason: "passed_test")
        }
        for name in genuineArchiveNowActive {
            try await flipToInactive(name, reason: "permanent")
        }
        for name in passedTestAlreadyInactive {
            try await correctReason(name)
        }
    }

    func revert(on database: Database) async throws {
        // No safe automatic revert — these are confirmed corrections against real client data.
    }
}

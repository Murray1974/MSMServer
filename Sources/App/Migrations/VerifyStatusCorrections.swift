import Fluent
import Vapor

/// Read-only verification — logs post-correction accountStatus + latest StudentStatusEvent
/// reason for all 19 students corrected by `CorrectStudentStatusMisclassifications` and
/// `CorrectOwnCarTestPasses`, confirming the end state matches what was intended.
struct VerifyStatusCorrections: AsyncMigration {
    func prepare(on database: Database) async throws {
        let names = [
            "Jayden Elliott", "Kacey Hill", "Autumn Avery", "Kaitlyn Aurora",
            "Molly Hoddinott", "Kelvin Nickles",
            "Ellie Prince", "Finnley Hancock", "Zoe Squire", "Karen Insignares",
            "Harvey Baker", "Eloise Styles", "Tyler Strong",
            "Chelsea Weeks", "Ruth Dumbreck", "Kody Taylor",
            "Callum Stevens", "Erin Le-Leivre", "Jake Gough"
        ]

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
                database.logger.notice("[Verify] '\(fullName)': no matching User row")
                continue
            }

            let profile = try await StudentProfile.query(on: database)
                .filter(\.$user.$id == userID)
                .first()
            let latestEvent = try await StudentStatusEvent.query(on: database)
                .filter(\.$student.$id == userID)
                .sort(\.$occurredAt, .descending)
                .first()

            database.logger.notice(
                "[Verify] '\(fullName)' accountStatus=\(profile?.accountStatus ?? "NO PROFILE") latestEventReason=\(latestEvent?.reason ?? "nil") latestEventOccurredAt=\(latestEvent?.occurredAt.description ?? "nil")"
            )
        }
    }

    func revert(on database: Database) async throws {}
}

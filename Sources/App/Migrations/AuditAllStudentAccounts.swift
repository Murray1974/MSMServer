import Fluent
import Vapor

/// One-time, read-only diagnostic — sweeps every student account (not just the 13 named
/// in `AuditMissingHourlyRatePresets`, which turned out to be clean except for 2 real
/// cases) to check for the same two issues: a missing `StudentProfile` row (breaks payment
/// presets + pickup-address defaults, see `BackfillMissingStudentProfiles`) and a true
/// duplicate account (two different `User` rows with the exact same first+last name —
/// unlike the earlier audit's loose OR-matched query, this groups by exact name so it
/// doesn't produce false positives like the "Oliver Forster"/"Oliver Noon" mismatch did).
/// Also logs the accountStatus split (active vs inactive/archived) and total count so it
/// can be cross-checked against the known 22 active + 3 archived = 25 total.
struct AuditAllStudentAccounts: AsyncMigration {
    func prepare(on database: Database) async throws {
        let students = try await User.query(on: database)
            .filter(\.$role == "student")
            .all()

        database.logger.notice("[AuditAll] total student User rows: \(students.count)")

        var activeCount = 0
        var inactiveCount = 0
        var noProfileCount = 0
        var zeroOrNilRateCount = 0

        var byName: [String: [User]] = [:]

        for student in students {
            guard let userID = student.id else { continue }
            let profile = try await StudentProfile.query(on: database)
                .filter(\.$user.$id == userID)
                .first()

            if let profile {
                if profile.accountStatus == "inactive" {
                    inactiveCount += 1
                } else {
                    activeCount += 1
                }
                if profile.hourlyRatePence <= 0 {
                    zeroOrNilRateCount += 1
                    database.logger.notice(
                        "[AuditAll] ZERO/NIL RATE: userID=\(userID) username=\(student.username) name=\(student.firstName ?? "") \(student.lastName ?? "") hourlyRatePence=\(profile.hourlyRatePence) accountStatus=\(profile.accountStatus)"
                    )
                }
            } else {
                noProfileCount += 1
                database.logger.notice(
                    "[AuditAll] MISSING PROFILE: userID=\(userID) username=\(student.username) name=\(student.firstName ?? "") \(student.lastName ?? "")"
                )
            }

            let nameKey = "\((student.firstName ?? "").lowercased())|\((student.lastName ?? "").lowercased())"
            byName[nameKey, default: []].append(student)
        }

        for (nameKey, users) in byName where users.count > 1 && nameKey != "|" {
            let ids = users.compactMap { $0.id?.uuidString }.joined(separator: ", ")
            let usernames = users.map { $0.username }.joined(separator: ", ")
            database.logger.notice(
                "[AuditAll] DUPLICATE NAME '\(nameKey)': \(users.count) accounts — userIDs=[\(ids)] usernames=[\(usernames)]"
            )
        }

        database.logger.notice(
            "[AuditAll] summary: activeWithProfile=\(activeCount) inactiveWithProfile=\(inactiveCount) missingProfile=\(noProfileCount) zeroOrNilRate=\(zeroOrNilRateCount)"
        )
    }

    func revert(on database: Database) async throws {}
}

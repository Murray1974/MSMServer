import Fluent
import Vapor

/// Follow-up to `AuditAllStudentAccounts` — that found 54 total student accounts (33
/// active, 21 inactive) against an expected 22 active + 3 archived. Logs every student's
/// name, username, accountStatus, and createdAt date so they can be manually checked
/// against the real client list.
struct ListAllStudentNamesAndStatus: AsyncMigration {
    func prepare(on database: Database) async throws {
        let students = try await User.query(on: database)
            .filter(\.$role == "student")
            .all()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        for student in students {
            guard let userID = student.id else { continue }
            let profile = try await StudentProfile.query(on: database)
                .filter(\.$user.$id == userID)
                .first()
            let createdDate = student.createdAt.map { formatter.string(from: $0) } ?? "unknown"
            database.logger.notice(
                "[StudentList] name='\(student.firstName ?? "") \(student.lastName ?? "")' username=\(student.username) accountStatus=\(profile?.accountStatus ?? "NO PROFILE") created=\(createdDate)"
            )
        }
    }

    func revert(on database: Database) async throws {}
}

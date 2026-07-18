import Vapor
import Fluent

struct InstructorPendingStudentsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws { }

    // MARK: - DTOs

    struct PendingStudentRow: Content {
        let id: UUID
        let firstName: String?
        let lastName: String?
        let email: String?
        let provisionalLicenceNumber: String?
        let dateOfBirth: Date?
        let transmissionPreference: String?
        let previousHours: Int?
        let socialMediaOptIn: Bool
        let createdAt: Date?
    }

    struct ApproveRequest: Content {
        let notes: String?
    }

    struct RejectRequest: Content {
        let reason: String
    }

    struct StatusResponse: Content {
        let approvalStatus: String
    }

    // MARK: - GET /instructor/students/pending

    func listPending(_ req: Request) async throws -> [PendingStudentRow] {
        let profiles = try await StudentProfile.query(on: req.db)
            .filter(\.$approvalStatus == "pending")
            .sort(\.$createdAt, .ascending)
            .all()

        return profiles.compactMap { p in
            guard let id = p.id else { return nil }
            return PendingStudentRow(
                id: id,
                firstName: p.firstName,
                lastName: p.lastName,
                email: p.email,
                provisionalLicenceNumber: p.provisionalLicenceNumber,
                dateOfBirth: p.dateOfBirth,
                transmissionPreference: p.transmissionPreference,
                previousHours: p.previousHours,
                socialMediaOptIn: p.socialMediaOptIn,
                createdAt: p.createdAt
            )
        }
    }

    // MARK: - POST /instructor/students/:profileID/approve

    func approve(_ req: Request) async throws -> HTTPStatus {
        guard let profileID = req.parameters.get("profileID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid profile ID.")
        }
        let input = try? req.content.decode(ApproveRequest.self)

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$id == profileID)
            .first()
        else {
            throw Abort(.notFound, reason: "Student profile not found.")
        }

        profile.approvalStatus = "approved"
        profile.approvalNotes = input?.notes
        try await profile.save(on: req.db)

        req.logger.notice("[Students] Approved pending student: \(profile.email ?? profileID.uuidString)")
        return .ok
    }

    // MARK: - POST /instructor/students/:profileID/reject

    func reject(_ req: Request) async throws -> HTTPStatus {
        guard let profileID = req.parameters.get("profileID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid profile ID.")
        }
        let input = try req.content.decode(RejectRequest.self)

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$id == profileID)
            .first()
        else {
            throw Abort(.notFound, reason: "Student profile not found.")
        }

        profile.approvalStatus = "rejected"
        profile.approvalNotes = input.reason
        try await profile.save(on: req.db)

        req.logger.notice("[Students] Rejected pending student: \(profile.email ?? profileID.uuidString) — \(input.reason)")
        return .ok
    }

    // MARK: - GET /student/status (student-facing)

    func studentStatus(_ req: Request) async throws -> StatusResponse {
        let token = try req.auth.require(SessionToken.self)
        let userID = token.$user.id

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "Profile not found.")
        }

        return StatusResponse(approvalStatus: profile.approvalStatus)
    }
}

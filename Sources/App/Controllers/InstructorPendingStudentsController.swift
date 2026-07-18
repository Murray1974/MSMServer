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
        let mobile: String?
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

    struct CompleteProfileRequest: Content {
        let tcVersion: String
        let gdprConsent: Bool
        let dashcamConsent: Bool
        let socialMediaOptIn: Bool
        let eyesightConfirmed: Bool
        let mobile: String?
        let dateOfBirth: Date?
        let transmissionPreference: String?
        let previousHours: Int?
        let provisionalLicenceNumber: String?
    }

    struct StatusResponse: Content {
        let approvalStatus: String
        let profileComplete: Bool
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
                mobile: p.mobile,
                provisionalLicenceNumber: p.provisionalLicenceNumber,
                dateOfBirth: p.dateOfBirth,
                transmissionPreference: p.transmissionPreference,
                previousHours: p.previousHours,
                socialMediaOptIn: p.socialMediaOptIn,
                createdAt: p.createdAt
            )
        }
    }

    // MARK: - POST /instructor/students/:studentID/approve

    func approve(_ req: Request) async throws -> HTTPStatus {
        guard let profileID = req.parameters.get("studentID", as: UUID.self) else {
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

    // MARK: - POST /instructor/students/:studentID/reject

    func reject(_ req: Request) async throws -> HTTPStatus {
        guard let profileID = req.parameters.get("studentID", as: UUID.self) else {
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

    // MARK: - POST /student/complete-profile

    func completeProfile(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let input = try req.content.decode(CompleteProfileRequest.self)

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "Profile not found.")
        }

        guard input.gdprConsent else {
            throw Abort(.unprocessableEntity, reason: "GDPR consent is required.")
        }
        guard input.dashcamConsent else {
            throw Abort(.unprocessableEntity, reason: "Dashcam consent is required.")
        }
        guard input.eyesightConfirmed else {
            throw Abort(.unprocessableEntity, reason: "Please confirm your eyesight meets the legal standard.")
        }

        let now = Date()
        if profile.tcAcceptedAt == nil {
            profile.tcAcceptedAt = now
            profile.tcVersion = input.tcVersion
        }
        if profile.gdprConsentAt == nil {
            profile.gdprConsentAt = now
        }
        if profile.dashcamConsentAt == nil {
            profile.dashcamConsentAt = now
        }
        if profile.eyesightConfirmedAt == nil {
            profile.eyesightConfirmedAt = now
        }
        profile.socialMediaOptIn = input.socialMediaOptIn
        if let m = input.mobile, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.mobile = m.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let dob = input.dateOfBirth, profile.dateOfBirth == nil {
            profile.dateOfBirth = dob
        }
        if let tp = input.transmissionPreference, profile.transmissionPreference == nil {
            profile.transmissionPreference = tp
        }
        if let ph = input.previousHours, profile.previousHours == nil {
            profile.previousHours = ph
        }
        if let ln = input.provisionalLicenceNumber, !ln.isEmpty {
            profile.provisionalLicenceNumber = ln
        }

        try await profile.save(on: req.db)
        req.logger.notice("[Students] Profile completed for user \(userID)")
        return .ok
    }

    // MARK: - GET /student/status (student-facing)

    func studentStatus(_ req: Request) async throws -> StatusResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "Profile not found.")
        }

        let profileComplete = profile.gdprConsentAt != nil
            && profile.dashcamConsentAt != nil
            && profile.tcAcceptedAt != nil
            && profile.eyesightConfirmedAt != nil

        return StatusResponse(approvalStatus: profile.approvalStatus, profileComplete: profileComplete)
    }
}

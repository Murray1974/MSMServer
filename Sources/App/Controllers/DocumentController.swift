import Vapor
import Fluent
import Foundation

struct StudentDocumentsDTO: Content {
    let theoryTestPassed: Bool
    let theoryTestDate: Date?
    let licencePhotoPath: String?
    let licenceVerified: Bool
    let provisionalLicenceNumber: String?
}

struct DocumentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - PATCH /student/documents — update theory test fields (JSON)

    func updateDocuments(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        struct DocumentInput: Content {
            var theoryTestPassed: Bool?
            var theoryTestDate: Date?
            var clearTheoryTestDate: Bool?
        }
        let input = try req.content.decode(DocumentInput.self)

        let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first() ?? StudentProfile(userID: userID)

        if let passed = input.theoryTestPassed { profile.theoryTestPassed = passed }
        if input.clearTheoryTestDate == true { profile.theoryTestDate = nil }
        else if let date = input.theoryTestDate { profile.theoryTestDate = date }

        try await profile.save(on: req.db)
        return .ok
    }

    // MARK: - POST /student/documents/photo — multipart photo upload

    func uploadPhoto(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        struct PhotoInput: Content {
            var photo: File
        }
        let input = try req.content.decode(PhotoInput.self)
        guard input.photo.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Photo data is empty.")
        }

        let uploadsDir = req.application.directory.workingDirectory + "uploads/licences"
        let filename = "\(userID.uuidString).jpg"
        let path = uploadsDir + "/" + filename
        try await req.fileio.writeFile(input.photo.data, at: path)

        let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first() ?? StudentProfile(userID: userID)
        profile.licencePhotoPath = "uploads/licences/\(filename)"
        profile.licenceVerified = false
        try await profile.save(on: req.db)
        return .ok
    }

    // MARK: - GET /student/documents/photo — student views their own photo

    func getOwnPhoto(_ req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        return try await streamPhoto(for: userID, req: req)
    }

    // MARK: - GET /instructor/student/:studentID/documents

    func instructorGetDocuments(_ req: Request) async throws -> StudentDocumentsDTO {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }
        let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .first()
        return StudentDocumentsDTO(
            theoryTestPassed: profile?.theoryTestPassed ?? false,
            theoryTestDate: profile?.theoryTestDate,
            licencePhotoPath: profile?.licencePhotoPath,
            licenceVerified: profile?.licenceVerified ?? false,
            provisionalLicenceNumber: profile?.provisionalLicenceNumber
        )
    }

    // MARK: - GET /instructor/student/:studentID/license-photo

    func instructorGetLicencePhoto(_ req: Request) async throws -> Response {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }
        return try await streamPhoto(for: studentID, req: req)
    }

    // MARK: - POST /instructor/student/:studentID/documents/verify

    func verifyLicence(_ req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }
        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .first() else {
            throw Abort(.notFound, reason: "Student profile not found.")
        }
        guard profile.licencePhotoPath != nil else {
            throw Abort(.badRequest, reason: "No licence photo to verify.")
        }
        profile.licenceVerified = true
        try await profile.save(on: req.db)
        req.application.broadcastDocumentStatusUpdated(studentID: studentID)
        return .ok
    }

    // MARK: - POST /instructor/student/:studentID/documents/revoke

    func revokeLicence(_ req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }
        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .first() else {
            throw Abort(.notFound, reason: "Student profile not found.")
        }
        profile.licenceVerified = false
        try await profile.save(on: req.db)
        req.application.broadcastDocumentStatusUpdated(studentID: studentID)
        return .ok
    }

    // MARK: - POST /student/profile/photo — multipart profile photo upload

    func uploadProfilePhoto(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        struct PhotoInput: Content {
            var photo: File
        }
        let input = try req.content.decode(PhotoInput.self)
        guard input.photo.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Photo data is empty.")
        }

        let uploadsDir = req.application.directory.workingDirectory + "uploads/profile_photos"
        let filename = "\(userID.uuidString).jpg"
        let path = uploadsDir + "/" + filename
        try await req.fileio.writeFile(input.photo.data, at: path)

        let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first() ?? StudentProfile(userID: userID)
        profile.profilePhotoPath = "uploads/profile_photos/\(filename)"
        profile.lastAvatarType = "photo"
        try await profile.save(on: req.db)
        return .ok
    }

    // MARK: - PUT /student/profile/avatar-emoji — sets an emoji avatar (kept alongside any saved photo)

    func setAvatarEmoji(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        struct EmojiInput: Content { var emoji: String }
        let input = try req.content.decode(EmojiInput.self)
        guard !input.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Emoji is required.")
        }

        let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first() ?? StudentProfile(userID: userID)
        profile.avatarEmoji = input.emoji
        profile.lastAvatarType = "emoji"
        try await profile.save(on: req.db)
        return .ok
    }

    // MARK: - DELETE /student/profile/avatar — clears any saved photo/emoji, reverting to initials

    func removeAvatar(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        else {
            return .ok
        }

        if let path = profile.profilePhotoPath {
            let fullPath = req.application.directory.workingDirectory + path
            try? FileManager.default.removeItem(atPath: fullPath)
        }
        profile.profilePhotoPath = nil
        profile.avatarEmoji = nil
        profile.lastAvatarType = nil
        try await profile.save(on: req.db)
        return .ok
    }

    // MARK: - GET /student/profile/photo — student views their own profile photo

    func getOwnProfilePhoto(_ req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        return try await streamProfilePhoto(for: userID, req: req)
    }

    // MARK: - GET /instructor/student/:studentID/profile-photo

    func instructorGetProfilePhoto(_ req: Request) async throws -> Response {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }
        return try await streamProfilePhoto(for: studentID, req: req)
    }

    // MARK: - Helper

    private func streamPhoto(for studentID: UUID, req: Request) async throws -> Response {
        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .first(),
              let photoPath = profile.licencePhotoPath else {
            throw Abort(.notFound, reason: "No licence photo on file.")
        }
        let fullPath = req.application.directory.workingDirectory + photoPath
        return req.fileio.streamFile(at: fullPath)
    }

    private func streamProfilePhoto(for studentID: UUID, req: Request) async throws -> Response {
        guard let profile = try await StudentProfile.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .first(),
              let photoPath = profile.profilePhotoPath else {
            throw Abort(.notFound, reason: "No profile photo on file.")
        }
        let fullPath = req.application.directory.workingDirectory + photoPath
        return req.fileio.streamFile(at: fullPath)
    }
}

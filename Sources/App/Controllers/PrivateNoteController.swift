import Vapor
import Fluent

struct PrivateNoteResponse: Content {
    let id: UUID
    let studentID: UUID
    let content: String
    let createdAt: Date?
    let updatedAt: Date?
}

struct PrivateNoteInput: Content {
    let content: String
}

struct PrivateNoteController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - GET /instructor/student/:studentID/private-notes

    func getPrivateNotes(_ req: Request) async throws -> [PrivateNoteResponse] {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can access private notes.")
        }
        let instructorID = try instructor.requireID()
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }

        let notes = try await PrivateNote.query(on: req.db)
            .filter(\.$studentID == studentID)
            .filter(\.$instructorID == instructorID)
            .sort(\.$createdAt, .descending)
            .all()

        return try notes.map { try toResponse($0) }
    }

    // MARK: - POST /instructor/student/:studentID/private-notes

    func createPrivateNote(_ req: Request) async throws -> PrivateNoteResponse {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can create private notes.")
        }
        let instructorID = try instructor.requireID()
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }

        let input = try req.content.decode(PrivateNoteInput.self)
        let trimmed = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Note content cannot be empty.")
        }

        let note = PrivateNote(studentID: studentID, instructorID: instructorID, content: trimmed)
        try await note.save(on: req.db)
        return try toResponse(note)
    }

    // MARK: - PATCH /instructor/private-notes/:noteID

    func updatePrivateNote(_ req: Request) async throws -> PrivateNoteResponse {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can edit private notes.")
        }
        let instructorID = try instructor.requireID()
        guard let noteID = req.parameters.get("noteID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing noteID.")
        }
        guard let note = try await PrivateNote.find(noteID, on: req.db) else {
            throw Abort(.notFound, reason: "Private note not found.")
        }
        guard note.instructorID == instructorID else {
            throw Abort(.forbidden, reason: "You do not own this note.")
        }

        let input = try req.content.decode(PrivateNoteInput.self)
        let trimmed = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Note content cannot be empty.")
        }

        note.content = trimmed
        try await note.save(on: req.db)
        return try toResponse(note)
    }

    // MARK: - DELETE /instructor/private-notes/:noteID

    func deletePrivateNote(_ req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can delete private notes.")
        }
        let instructorID = try instructor.requireID()
        guard let noteID = req.parameters.get("noteID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing noteID.")
        }
        guard let note = try await PrivateNote.find(noteID, on: req.db) else {
            throw Abort(.notFound, reason: "Private note not found.")
        }
        guard note.instructorID == instructorID else {
            throw Abort(.forbidden, reason: "You do not own this note.")
        }

        try await note.delete(on: req.db)
        return .noContent
    }

    // MARK: - Helper

    private func toResponse(_ note: PrivateNote) throws -> PrivateNoteResponse {
        PrivateNoteResponse(
            id: try note.requireID(),
            studentID: note.studentID,
            content: note.content,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt
        )
    }
}

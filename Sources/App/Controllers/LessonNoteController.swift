import Vapor
import Fluent

struct LessonNoteResponse: Content {
    let id: UUID
    let studentID: UUID
    let content: String
    let createdAt: Date?
}

struct CreateLessonNoteInput: Content {
    let content: String
}

struct LessonNoteController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - POST /instructor/student/:studentID/notes

    func createNote(_ req: Request) async throws -> LessonNoteResponse {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can post lesson notes.")
        }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }

        let input = try req.content.decode(CreateLessonNoteInput.self)
        let trimmed = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Note content cannot be empty.")
        }

        let note = LessonNote(studentID: studentID, content: trimmed)
        try await note.save(on: req.db)

        // ── FCM push notification ─────────────────────────────────────────────
        if let fcmToken = try await User.find(studentID, on: req.db)?.fcmToken,
           let fcm = FCMNotificationService(req: req) {
            let name = instructor.firstName ?? "Your instructor"
            try? await fcm.send(
                to: fcmToken,
                title: "New Lesson Note! 📝",
                body: "Tap to see \(name)'s feedback."
            )
        }

        return LessonNoteResponse(
            id: try note.requireID(),
            studentID: note.studentID,
            content: note.content,
            createdAt: note.createdAt
        )
    }

    // MARK: - GET /instructor/student/:studentID/notes

    func instructorGetNotes(_ req: Request) async throws -> [LessonNoteResponse] {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can view lesson notes.")
        }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }

        return try await fetchNotes(studentID: studentID, db: req.db)
    }

    // MARK: - GET /student/notes

    func studentNotes(_ req: Request) async throws -> [LessonNoteResponse] {
        let studentID = try req.auth.require(User.self).requireID()
        return try await fetchNotes(studentID: studentID, db: req.db)
    }

    // MARK: - PATCH /instructor/notes/:noteID

    func updateNote(_ req: Request) async throws -> LessonNoteResponse {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can edit notes.")
        }
        guard let noteID = req.parameters.get("noteID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing noteID.")
        }
        guard let note = try await LessonNote.find(noteID, on: req.db) else {
            throw Abort(.notFound, reason: "Note not found.")
        }

        let input = try req.content.decode(CreateLessonNoteInput.self)
        let trimmed = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Note content cannot be empty.")
        }

        note.content = trimmed
        try await note.save(on: req.db)

        req.application.broadcastNoteUpdated(studentID: note.studentID)

        return LessonNoteResponse(
            id: try note.requireID(),
            studentID: note.studentID,
            content: note.content,
            createdAt: note.createdAt
        )
    }

    // MARK: - DELETE /instructor/notes/:noteID

    func deleteNote(_ req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can delete notes.")
        }
        guard let noteID = req.parameters.get("noteID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing noteID.")
        }
        guard let note = try await LessonNote.find(noteID, on: req.db) else {
            throw Abort(.notFound, reason: "Note not found.")
        }

        let studentID = note.studentID
        try await note.delete(on: req.db)

        req.application.broadcastNoteUpdated(studentID: studentID)

        return .noContent
    }

    // MARK: - Shared helper

    private func fetchNotes(studentID: UUID, db: Database) async throws -> [LessonNoteResponse] {
        let notes = try await LessonNote.query(on: db)
            .filter(\.$studentID == studentID)
            .sort(\.$createdAt, .descending)
            .limit(50)
            .all()

        return try notes.map { note in
            LessonNoteResponse(
                id: try note.requireID(),
                studentID: note.studentID,
                content: note.content,
                createdAt: note.createdAt
            )
        }
    }
}

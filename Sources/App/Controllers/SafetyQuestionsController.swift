import Vapor
import Fluent

struct SafetyQuestionsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // ── DTO ──────────────────────────────────────────────────────────────────────

    struct SafetyQuestionRow: Content {
        let questionID: UUID
        let questionText: String
        let answerText: String
        let type: String
        let displayOrder: Int
        let mastered: Bool
    }

    // ── Shared helper ────────────────────────────────────────────────────────────

    private func buildRows(studentID: UUID, db: Database) async throws -> [SafetyQuestionRow] {
        async let questionsResult  = SafetyQuestion.query(on: db).sort(\.$displayOrder).all()
        async let progressesResult = StudentSafetyProgress.query(on: db)
            .filter(\.$student.$id == studentID).all()

        let (questions, progresses) = try await (questionsResult, progressesResult)

        var masteredByQuestionID = Set<UUID>()
        for p in progresses where p.mastered {
            masteredByQuestionID.insert(p.$question.id)
        }

        return try questions.map { q in
            let qID = try q.requireID()
            return SafetyQuestionRow(
                questionID:   qID,
                questionText: q.questionText,
                answerText:   q.answerText,
                type:         q.type,
                displayOrder: q.displayOrder,
                mastered:     masteredByQuestionID.contains(qID)
            )
        }
    }

    // ── GET /student/safety-questions ────────────────────────────────────────────

    func studentGetQuestions(req: Request) async throws -> [SafetyQuestionRow] {
        let user = try req.auth.require(User.self)
        let studentID = try user.requireID()
        return try await buildRows(studentID: studentID, db: req.db)
    }

    // ── GET /instructor/student/:studentID/safety-questions ──────────────────────

    func instructorGetQuestions(req: Request) async throws -> [SafetyQuestionRow] {
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid studentID")
        }
        return try await buildRows(studentID: studentID, db: req.db)
    }

    // ── PATCH /instructor/student/:studentID/safety-questions/:questionID ────────
    // Body: { "mastered": true }

    func instructorSetMastered(req: Request) async throws -> SafetyQuestionRow {
        guard let studentID  = req.parameters.get("studentID",  as: UUID.self),
              let questionID = req.parameters.get("questionID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        struct MasteredInput: Content { var mastered: Bool }
        let input = try req.content.decode(MasteredInput.self)

        // Upsert: find existing record or create a new one
        if let existing = try await StudentSafetyProgress.query(on: req.db)
            .filter(\.$student.$id == studentID)
            .filter(\.$question.$id == questionID)
            .first() {
            existing.mastered = input.mastered
            try await existing.save(on: req.db)
        } else {
            let record = StudentSafetyProgress(
                studentID:  studentID,
                questionID: questionID,
                mastered:   input.mastered
            )
            try await record.save(on: req.db)
        }

        // Return updated row list item
        guard let question = try await SafetyQuestion.find(questionID, on: req.db) else {
            throw Abort(.notFound, reason: "Question not found")
        }
        return SafetyQuestionRow(
            questionID:   questionID,
            questionText: question.questionText,
            answerText:   question.answerText,
            type:         question.type,
            displayOrder: question.displayOrder,
            mastered:     input.mastered
        )
    }
}

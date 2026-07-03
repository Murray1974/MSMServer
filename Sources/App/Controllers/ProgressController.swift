import Vapor
import Fluent

struct ProgressController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - Shared helper

    /// Loads all 27 topics and a student's progress records, then zips them
    /// into the full response shape.  Used by both the student and instructor
    /// GET endpoints so the logic stays in one place.
    private func buildResponse(studentID: UUID, db: Database) async throws -> StudentProgressResponse {
        async let allTopicsResult = SyllabusTopic.query(on: db).sort(\.$displayOrder).all()
        async let progressesResult = StudentProgress.query(on: db).filter(\.$student.$id == studentID).all()
        async let studentResult = User.find(studentID, on: db)

        let (allTopics, progresses, student) = try await (allTopicsResult, progressesResult, studentResult)

        var levelByTopicID: [UUID: (level: Int, updatedAt: Date?)] = [:]
        for p in progresses {
            levelByTopicID[p.$topic.id] = (p.level, p.updatedAt)
        }

        let items = try allTopics.map { topic -> ProgressTopicItem in
            let topicID = try topic.requireID()
            let entry = levelByTopicID[topicID]
            return ProgressTopicItem(
                topicID: topicID,
                topicName: topic.name,
                category: topic.category,
                displayOrder: topic.displayOrder,
                level: entry?.level ?? 0,
                updatedAt: entry?.updatedAt
            )
        }

        let testReadyCount = items.filter { $0.level >= 4 }.count
        let total = max(1, allTopics.count)
        let pct = (Double(testReadyCount) / Double(total)) * 100.0

        return StudentProgressResponse(
            testReadyPercentage: (pct * 10).rounded() / 10,
            topics: items,
            testDate: student?.testDate
        )
    }

    // MARK: - GET /student/progress

    /// Returns the authenticated student's own progress across all 27 topics.
    func studentProgress(_ req: Request) async throws -> StudentProgressResponse {
        let studentID = try req.auth.require(User.self).requireID()
        return try await buildResponse(studentID: studentID, db: req.db)
    }

    // MARK: - GET /instructor/student/:studentID/progress

    /// Returns any student's progress (instructor view — same shape as the
    /// student endpoint so the macOS app and Flutter app share one DTO).
    func instructorGetProgress(_ req: Request) async throws -> StudentProgressResponse {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can view student progress.")
        }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }
        return try await buildResponse(studentID: studentID, db: req.db)
    }

    // MARK: - PATCH /instructor/student/:studentID/progress

    /// Upserts a single topic's level for a student.
    ///
    /// Body: `{ "topicID": "<uuid>", "level": <1-5> }`
    func updateProgress(_ req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can update student progress.")
        }
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID.")
        }

        let input = try req.content.decode(UpdateProgressInput.self)

        // ── Test date update ──────────────────────────────────────────────────
        if input.clearTestDate == true || input.testDate != nil {
            guard let student = try await User.find(studentID, on: req.db) else {
                throw Abort(.notFound, reason: "Student not found.")
            }
            student.testDate = (input.clearTestDate == true) ? nil : input.testDate
            try await student.save(on: req.db)
            req.application.broadcastProgressUpdated(studentID: studentID, topicName: "testDate", level: 0)
            return .ok
        }

        // ── Topic level update ────────────────────────────────────────────────
        guard let topicID = input.topicID, let level = input.level else {
            throw Abort(.badRequest, reason: "Supply topicID+level, testDate, or clearTestDate.")
        }
        guard (1...5).contains(level) else {
            throw Abort(.badRequest, reason: "Level must be between 1 and 5.")
        }
        guard let topic = try await SyllabusTopic.find(topicID, on: req.db) else {
            throw Abort(.notFound, reason: "Syllabus topic not found.")
        }

        if let existing = try await StudentProgress.query(on: req.db)
            .filter(\.$student.$id == studentID)
            .filter(\.$topic.$id == topicID)
            .first() {
            existing.level = level
            try await existing.save(on: req.db)
        } else {
            let progress = StudentProgress(studentID: studentID, topicID: topicID, level: level)
            try await progress.save(on: req.db)
        }

        req.application.broadcastProgressUpdated(studentID: studentID, topicName: topic.name, level: level)

        if let fcmToken = try await User.find(studentID, on: req.db)?.fcmToken,
           let fcm = FCMNotificationService(req: req) {
            try? await fcm.send(
                to: fcmToken,
                title: "Progress Update! 🚗",
                body: "Your \(topic.name) has been updated to Level \(level)."
            )
        }

        return .ok
    }
}

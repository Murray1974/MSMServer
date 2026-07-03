import Vapor

/// One topic row returned to the student app and instructor app.
struct ProgressTopicItem: Content {
    let topicID: UUID
    let topicName: String
    let category: String
    let displayOrder: Int
    /// 0 = not yet assessed; 1–5 = competency level.
    let level: Int
    /// ISO-8601 timestamp of the last instructor update, nil if never set.
    let updatedAt: Date?
}

/// Full response for GET /student/progress and GET /instructor/student/:id/progress.
struct StudentProgressResponse: Content {
    /// Percentage of the 27 topics rated at level 4 or 5 (0–100).
    let testReadyPercentage: Double
    let topics: [ProgressTopicItem]
    /// The student's scheduled practical test date, if set.
    let testDate: Date?
}

/// Body for PATCH /instructor/student/:studentID/progress.
/// All fields are optional — supply topicID+level to update a topic,
/// testDate to set a test date, or clearTestDate=true to remove it.
struct UpdateProgressInput: Content {
    let topicID: UUID?
    let level: Int?
    let testDate: Date?
    let clearTestDate: Bool?
}

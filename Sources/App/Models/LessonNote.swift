import Vapor
import Fluent

final class LessonNote: Model, Content, @unchecked Sendable {
    static let schema = "lesson_notes"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "student_id")
    var studentID: UUID

    @Field(key: "content")
    var content: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, studentID: UUID, content: String) {
        self.id = id
        self.studentID = studentID
        self.content = content
    }
}

import Vapor
import Fluent

final class PrivateNote: Model, Content, @unchecked Sendable {
    static let schema = "private_notes"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "student_id")
    var studentID: UUID

    @Field(key: "instructor_id")
    var instructorID: UUID

    @Field(key: "content")
    var content: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, studentID: UUID, instructorID: UUID, content: String) {
        self.id = id
        self.studentID = studentID
        self.instructorID = instructorID
        self.content = content
    }
}

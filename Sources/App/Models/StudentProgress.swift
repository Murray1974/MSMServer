import Fluent
import Vapor

final class StudentProgress: Model, Content, @unchecked Sendable {
    static let schema = "student_progress"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "student_id")
    var student: User

    @Parent(key: "topic_id")
    var topic: SyllabusTopic

    /// Competency level: 1 (introduced) → 5 (test-ready / independent).
    @Field(key: "level")
    var level: Int

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, studentID: UUID, topicID: UUID, level: Int) {
        self.id = id
        self.$student.id = studentID
        self.$topic.id = topicID
        self.level = level
    }
}

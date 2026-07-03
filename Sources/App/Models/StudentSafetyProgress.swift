import Fluent
import Vapor

final class StudentSafetyProgress: Model, Content, @unchecked Sendable {
    static let schema = "student_safety_progress"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "student_id")
    var student: User

    @Parent(key: "question_id")
    var question: SafetyQuestion

    @Field(key: "mastered")
    var mastered: Bool

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, studentID: UUID, questionID: UUID, mastered: Bool = false) {
        self.id = id
        self.$student.id = studentID
        self.$question.id = questionID
        self.mastered = mastered
    }
}

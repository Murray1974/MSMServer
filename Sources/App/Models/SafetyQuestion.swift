import Fluent
import Vapor

final class SafetyQuestion: Model, Content, @unchecked Sendable {
    static let schema = "safety_questions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "question_text")
    var questionText: String

    @Field(key: "answer_text")
    var answerText: String

    /// "show_me" or "tell_me"
    @Field(key: "type")
    var type: String

    @Field(key: "display_order")
    var displayOrder: Int

    init() {}

    init(id: UUID? = nil, questionText: String, answerText: String, type: String, displayOrder: Int) {
        self.id = id
        self.questionText = questionText
        self.answerText = answerText
        self.type = type
        self.displayOrder = displayOrder
    }
}

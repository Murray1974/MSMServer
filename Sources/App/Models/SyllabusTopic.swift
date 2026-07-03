import Fluent
import Vapor

final class SyllabusTopic: Model, Content, @unchecked Sendable {
    static let schema = "syllabus_topics"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "category")
    var category: String

    /// Absolute ordering across the full syllabus (1–27).
    @Field(key: "display_order")
    var displayOrder: Int

    init() {}

    init(id: UUID? = nil, name: String, category: String, displayOrder: Int) {
        self.id = id
        self.name = name
        self.category = category
        self.displayOrder = displayOrder
    }
}

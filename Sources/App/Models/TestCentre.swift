import Vapor
import Fluent

final class TestCentre: Model, Content, @unchecked Sendable {
    static let schema = "test_centres"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @OptionalField(key: "address")
    var address: String?

    // JSON-encoded [String] of "HH:mm" times, e.g. ["08:57","09:54","11:01"]
    @Field(key: "known_times")
    var knownTimes: String

    @Field(key: "is_primary")
    var isPrimary: Bool

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, address: String? = nil, knownTimes: [String] = [], isPrimary: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.isPrimary = isPrimary
        self.knownTimes = (try? String(data: JSONEncoder().encode(knownTimes), encoding: .utf8)) ?? "[]"
    }
}

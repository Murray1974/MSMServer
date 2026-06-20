import Vapor
import Fluent

final class TestCentre: Model, Content, @unchecked Sendable {
    static let schema = "test_centres"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    // JSON-encoded [String] of "HH:mm" times, e.g. ["08:57","09:54","11:01"]
    @Field(key: "known_times")
    var knownTimes: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, knownTimes: [String] = []) {
        self.id = id
        self.name = name
        self.knownTimes = (try? String(data: JSONEncoder().encode(knownTimes), encoding: .utf8)) ?? "[]"
    }
}

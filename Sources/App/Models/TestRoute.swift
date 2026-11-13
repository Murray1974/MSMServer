import Fluent
import Vapor

/// A named test/mock-test route the instructor has pre-built — e.g. a known local DVSA
/// test route or an ADI Standards Check practice route — with an optional attached GPX
/// track and a separate "directions" file describing it in words. Stored the same way as
/// every other file upload in this app: binary content on local disk under `uploads/`,
/// only the relative path kept here (see DocumentController's licence/profile photo
/// handling for the identical pattern). `uploads/` is a persistent Docker volume (fixed
/// 7 Nov 2026 — see docker-compose.yml), so paths survive redeploys.
final class TestRoute: Model, Content, @unchecked Sendable {
    static let schema = "test_routes"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "instructor_id")
    var instructor: User

    @Field(key: "name")
    var name: String

    @OptionalField(key: "gpx_path")
    var gpxPath: String?

    /// Kept alongside the path so the client can show/download using the original
    /// filename the instructor picked, rather than the UUID-based name it's stored under.
    @OptionalField(key: "gpx_original_filename")
    var gpxOriginalFilename: String?

    @OptionalField(key: "directions_path")
    var directionsPath: String?

    @OptionalField(key: "directions_original_filename")
    var directionsOriginalFilename: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, instructorID: UUID, name: String) {
        self.id = id
        self.$instructor.id = instructorID
        self.name = name
    }
}

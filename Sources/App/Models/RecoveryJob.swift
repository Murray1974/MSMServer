import Fluent
import Vapor

final class RecoveryJob: Model, @unchecked Sendable {
    static let schema = "recovery_jobs"

    @ID(key: .id) var id: UUID?
    @Field(key: "lesson_id") var lessonID: UUID
    @Field(key: "stage") var stage: String
    @Field(key: "scheduled_for") var scheduledFor: Date
    @OptionalField(key: "sent_at") var sentAt: Date?
    @OptionalField(key: "cancelled_at") var cancelledAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(lessonID: UUID, stage: String, scheduledFor: Date) {
        self.lessonID = lessonID
        self.stage = stage
        self.scheduledFor = scheduledFor
    }
}

import Vapor
import Fluent

final class TestAppointment: Model, Content, @unchecked Sendable {
    static let schema = "test_appointments"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "student_name")
    var studentName: String

    @Field(key: "test_time")
    var testTime: String // HH:mm — actual test appointment time within the lesson slot

    @OptionalField(key: "test_location")
    var testLocation: String?

    @OptionalField(key: "test_centre")
    var testCentre: String?

    @Field(key: "test_ref")
    var testRef: String // "Required" if not yet confirmed

    @Field(key: "cancel_by_date")
    var cancelByDate: String // yyyy-MM-dd

    @Field(key: "starts_at")
    var startsAt: Date // lesson slot start

    @Field(key: "ends_at")
    var endsAt: Date // lesson slot end

    @Field(key: "state")
    var state: String // "scheduled" | "attended" | "cancelled"

    // "pending" = student submitted, awaiting instructor confirmation
    // "confirmed" = instructor approved (default for instructor-created)
    // "rejected" = instructor declined
    @Field(key: "status")
    var status: String

    // "instructor" = created by instructor, "student" = submitted by student
    @Field(key: "submitted_by")
    var submittedBy: String

    @OptionalField(key: "ek_event_id")
    var ekEventID: String?

    @OptionalParent(key: "charged_ledger_entry_id")
    var chargedLedgerEntry: LedgerEntry?

    // Result fields — filled in by instructor after the test
    @OptionalField(key: "examiner")
    var examiner: String?

    @OptionalField(key: "outcome")
    var outcome: String? // "pass" | "fail"

    @OptionalField(key: "faults")
    var faults: String? // JSON-encoded [String]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        studentName: String,
        testTime: String,
        testLocation: String? = nil,
        testCentre: String? = nil,
        testRef: String,
        cancelByDate: String,
        startsAt: Date,
        endsAt: Date,
        state: String = "scheduled",
        status: String = "confirmed",
        submittedBy: String = "instructor",
        ekEventID: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.studentName = studentName
        self.testTime = testTime
        self.testLocation = testLocation
        self.testCentre = testCentre
        self.testRef = testRef
        self.cancelByDate = cancelByDate
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.state = state
        self.status = status
        self.submittedBy = submittedBy
        self.ekEventID = ekEventID
    }
}

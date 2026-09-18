//
//  StudentStatusEvent.swift
//  MSMServer
//

import Vapor
import Fluent

/// Append-only log of every active/inactive transition for a student, used to derive
/// turnover/retention metrics (Loss, Regained, Completions) on a month-by-month basis.
/// `reason` on an active->inactive transition is one of:
///   - "temporary"           student/instructor declared this a temporary hold — counts as
///                           retention until reclassified (see `TempHoldReclassificationService`)
///   - "permanent"           declared a permanent loss at time of toggle
///   - "passed_test"         instructor archived the client because they passed their test —
///                           a completion, not a loss
///   - "auto_archive"        the 28-day inactivity system deactivated them with no human toggle —
///                           counts as an immediate loss
///   - "reclassified_to_loss" synthetic event written by the reclassification job when a
///                           "temporary" hold has remained inactive for 12+ weeks; `fromStatus`
///                           and `toStatus` are both "inactive" (no real status change) — this
///                           event's `occurredAt` is what attributes the loss to a given month
/// An active->inactive transition with `reason == nil` (student self-toggle before the
/// temporary/permanent prompt existed client-side) is treated as "temporary" for metrics
/// purposes — see `StudentMetricsService`.
final class StudentStatusEvent: Model, Content, @unchecked Sendable {
    static let schema = "student_status_events"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "student_id")
    var student: User

    @Field(key: "from_status")
    var fromStatus: String

    @Field(key: "to_status")
    var toStatus: String

    @OptionalField(key: "reason")
    var reason: String?

    @Field(key: "occurred_at")
    var occurredAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        studentID: UUID,
        fromStatus: String,
        toStatus: String,
        reason: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.$student.id = studentID
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.reason = reason
        self.occurredAt = occurredAt
    }
}

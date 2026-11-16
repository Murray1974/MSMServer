import Vapor

/// One row of the "clients by time since last lesson" list — surfaces
/// `StudentProfile.lastAttendedLessonAt` (already maintained by `ConfirmedLessonController`
/// and the 14/21/28-day inactivity system) so an instructor can see at a glance who hasn't
/// had a lesson in a while, sorted longest-since-last-lesson first.
struct ClientLastLessonRow: Content {
    let studentID: UUID
    let name: String
    let lastAttendedLessonAt: Date?
    /// Nil when the student has never had an attended lesson — treated as the most
    /// overdue case by the controller's sort, not excluded from the list.
    let daysSinceLastLesson: Int?
    /// True when the student has at least one active (non-cancelled) booking for a
    /// lesson that hasn't started yet — lets the client flag "no upcoming lesson" even
    /// for a client who was seen recently.
    let hasUpcomingLesson: Bool
}

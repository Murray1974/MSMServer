import Vapor
import Fluent

/// Derives month-by-month student turnover/retention metrics from the StudentStatusEvent log.
///
/// Classification rules (agreed with the instructor):
///   - Loss: a "permanent" toggle, an "auto_archive" (28-day silent inactivity), or a
///     "temporary" hold that reached 12 weeks still inactive ("reclassified_to_loss").
///   - Regained: a reactivation (inactive -> active) that follows an established loss, with no
///     intervening reactivation. A student reactivating out of a "temporary" hold that never
///     reached the 12-week mark was never counted as a loss, so that reactivation is not
///     "regained" — they were retained the whole time.
///   - Completions: "passed_test" archives — a success, tracked separately from loss/retention.
///   - Retention rate (per month): of students who'd already had a first lesson 12 months before
///     that month's end, what fraction are not currently in a "lost" state as of that month end
///     (this includes students still mid-way through an unresolved "temporary" hold).
struct StudentMetricsService {

    let db: Database

    struct MonthlyBucket: Content {
        var monthStart: Date
        var label: String
        var losses: Int
        var regained: Int
        var completions: Int
        var retentionRate: Double?
    }

    struct TurnoverMetrics: Content {
        var months: [MonthlyBucket]
    }

    static let lossReasons: Set<String> = ["permanent", "auto_archive", "reclassified_to_loss"]

    private static func londonCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        return calendar
    }

    func turnoverMetrics(months monthCount: Int) async throws -> TurnoverMetrics {
        let allEvents = try await StudentStatusEvent.query(on: db)
            .sort(\.$occurredAt, .ascending)
            .all()
        let eventsByStudent = Dictionary(grouping: allEvents, by: { $0.$student.id })

        let profiles = try await StudentProfile.query(on: db).all()
        let firstLessonByStudent: [UUID: Date] = Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
            guard let first = profile.firstLessonConfirmedAt else { return nil }
            return (profile.$user.id, first)
        })

        let calendar = Self.londonCalendar()
        guard let thisMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) else {
            return TurnoverMetrics(months: [])
        }

        var buckets: [MonthlyBucket] = []
        for offset in stride(from: monthCount - 1, through: 0, by: -1) {
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: thisMonthStart),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { continue }

            var losses = 0
            var regained = 0
            var completions = 0
            for event in allEvents where event.occurredAt >= monthStart && event.occurredAt < monthEnd {
                if let reason = event.reason, Self.lossReasons.contains(reason) {
                    losses += 1
                } else if event.toStatus == "active" && event.fromStatus == "inactive" {
                    let history = eventsByStudent[event.$student.id] ?? []
                    if wasLostJustBefore(event, in: history) {
                        regained += 1
                    }
                }
                if event.reason == "passed_test" {
                    completions += 1
                }
            }

            var retentionRate: Double? = nil
            if let cohortCutoff = calendar.date(byAdding: .month, value: -12, to: monthEnd) {
                let cohort = firstLessonByStudent.filter { $0.value <= cohortCutoff }
                if !cohort.isEmpty {
                    let retainedCount = cohort.keys.reduce(into: 0) { count, studentID in
                        let history = eventsByStudent[studentID] ?? []
                        if !isLost(events: history, asOf: monthEnd) { count += 1 }
                    }
                    retentionRate = Double(retainedCount) / Double(cohort.count)
                }
            }

            buckets.append(MonthlyBucket(
                monthStart: monthStart,
                label: Self.label(for: monthStart),
                losses: losses,
                regained: regained,
                completions: completions,
                retentionRate: retentionRate
            ))
        }

        return TurnoverMetrics(months: buckets)
    }

    /// Whether the student was in a "lost" state immediately before `event` — confirms a
    /// reactivation is a genuine "regained" rather than a routine unpause of a still-within-grace
    /// temporary hold.
    private func wasLostJustBefore(_ event: StudentStatusEvent, in history: [StudentStatusEvent]) -> Bool {
        let priorEvents = history.filter { $0.occurredAt < event.occurredAt }
        return isLost(events: priorEvents, asOf: event.occurredAt)
    }

    /// Replays a student's event history up to `asOf` to determine whether they're currently
    /// counted as a loss at that point in time.
    private func isLost(events: [StudentStatusEvent], asOf: Date) -> Bool {
        var lost = false
        for event in events where event.occurredAt <= asOf {
            if let reason = event.reason, Self.lossReasons.contains(reason) {
                lost = true
            } else if event.toStatus == "active" {
                lost = false
            }
        }
        return lost
    }

    private static func label(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        return formatter.string(from: date)
    }
}

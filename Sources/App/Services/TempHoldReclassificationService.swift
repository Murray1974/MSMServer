import Vapor
import Fluent

/// Runs every 6 hours via TempHoldReclassificationLifecycle.
/// A "temporary" hold (student or instructor declared this pause non-permanent) counts as
/// retention, not loss, for turnover metrics — unless the student remains inactive for 12 weeks
/// from the toggle date, at which point it converts to a loss. This scans for exactly that case
/// and writes a synthetic "reclassified_to_loss" StudentStatusEvent (no real status change) so
/// the metrics aggregation attributes the loss to the month it actually converts in.
struct TempHoldReclassificationService {

    let db: Database
    let logger: Logger

    static let holdWindow: TimeInterval = 12 * 7 * 24 * 60 * 60 // 12 weeks

    func runCycle() async {
        logger.notice("[TempHoldReclassification] Cycle started at \(Date())")

        let cutoff = Date().addingTimeInterval(-Self.holdWindow)

        let candidates: [StudentStatusEvent]
        do {
            candidates = try await StudentStatusEvent.query(on: db)
                .filter(\.$reason == "temporary")
                .filter(\.$toStatus == "inactive")
                .filter(\.$occurredAt <= cutoff)
                .all()
        } catch {
            logger.error("[TempHoldReclassification] Failed to query candidate events: \(error)")
            return
        }

        var reclassified = 0
        for event in candidates {
            guard await shouldReclassify(event) else { continue }
            let studentID = event.$student.id
            let record = StudentStatusEvent(
                studentID: studentID,
                fromStatus: "inactive",
                toStatus: "inactive",
                reason: "reclassified_to_loss",
                occurredAt: Date()
            )
            try? await record.save(on: db)
            reclassified += 1
            logger.notice("[TempHoldReclassification] Reclassified student \(studentID) temp-hold from \(event.occurredAt) to a loss.")
        }

        logger.notice("[TempHoldReclassification] Cycle complete — reclassified \(reclassified) of \(candidates.count) candidate(s).")
    }

    /// A temp-hold event should convert to a loss only if the student is still inactive right
    /// now, hasn't reactivated since, and hasn't already been reclassified from this same event.
    private func shouldReclassify(_ event: StudentStatusEvent) async -> Bool {
        let studentID = event.$student.id

        guard let profile = try? await StudentProfile.query(on: db)
            .filter(\.$user.$id == studentID)
            .first(),
            profile.accountStatus == "inactive"
        else { return false }

        let laterEvents = (try? await StudentStatusEvent.query(on: db)
            .filter(\.$student.$id == studentID)
            .filter(\.$occurredAt > event.occurredAt)
            .all()) ?? []

        // Any reactivation or prior reclassification after this hold began means this specific
        // hold has already been resolved one way or another — don't double count it.
        let alreadyResolved = laterEvents.contains { $0.toStatus == "active" || $0.reason == "reclassified_to_loss" }
        return !alreadyResolved
    }
}

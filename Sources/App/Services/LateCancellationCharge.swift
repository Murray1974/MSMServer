import Vapor
import Fluent

/// Shared late-cancellation charge logic — stamps a booking as a late cancellation,
/// flags its LessonFinance as fully billable, and auto-debits the student's ledger.
/// Used by both the student-initiated cancel flow (StudentBookingsController) and the
/// instructor "Student Cancellation" swipe when confirmed within the 48h window
/// (BookingsController). Does NOT delete the booking or free the lesson slot —
/// callers handle that themselves afterwards, since the two call sites do it slightly
/// differently (single booking vs. a lesson's full active-booking set).
enum LateCancellationCharge {
    static func apply(
        booking: Booking,
        lesson: Lesson,
        studentID: UUID,
        cancellationSource: String,
        on db: Database
    ) async throws {
        booking.cancellationType = "late_cancellation"
        booking.cancellationSource = cancellationSource
        try await booking.save(on: db)

        let lessonID = lesson.id
        var lessonFinance: LessonFinance? = nil
        if let lid = lessonID {
            lessonFinance = try await LessonFinance.find(lid, on: db)
        }

        if let finance = lessonFinance {
            finance.fullChargeApplied = true
            try await finance.save(on: db)
        }

        let chargeAmount: Decimal
        if let snapshot = lessonFinance?.priceSnapshot {
            chargeAmount = snapshot
        } else {
            let mins = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
            let studentProfile = try await StudentProfile.query(on: db)
                .filter(\.$user.$id == studentID)
                .first()
            chargeAmount = LessonFinance.calculatedPrice(durationMinutes: mins, hourlyRate: studentProfile?.hourlyRate ?? 45)
        }

        let instructorIDFromFinance: UUID? = lessonFinance?.$instructor.id
        let instructorID: UUID?
        if let iid = instructorIDFromFinance {
            instructorID = iid
        } else {
            instructorID = try? await User.query(on: db).filter(\.$role == "instructor").first()?.requireID()
        }

        guard let lid = lessonID, let instructorID else { return }

        // Guard against a race with another charge path (e.g. auto-cancel service).
        let existingCharge = try await LedgerEntry.query(on: db)
            .filter(\.$lesson.$id == lid)
            .filter(\.$type == "late_cancellation_charge")
            .first()
        guard existingCharge == nil else { return }

        let chargeEntry = LedgerEntry(
            studentID: studentID,
            instructorID: instructorID,
            lessonID: lid,
            type: "late_cancellation_charge",
            amount: -chargeAmount,
            note: "Late cancellation — full charge applies",
            effectiveDate: Date(),
            createdByUserID: instructorID
        )
        try await chargeEntry.save(on: db)
    }
}

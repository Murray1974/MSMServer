import Vapor
import Fluent

final class LessonFinance: Model, Content, @unchecked Sendable {
    static let schema = "lesson_finance"

    @ID(custom: "lesson_id", generatedBy: .user)
    var id: UUID?

    @Parent(key: "student_id")
    var student: User

    @Parent(key: "instructor_id")
    var instructor: User

    @Field(key: "duration_minutes")
    var durationMinutes: Int

    @Field(key: "hourly_rate_snapshot")
    var hourlyRateSnapshot: Decimal

    @Field(key: "price_snapshot")
    var priceSnapshot: Decimal

    @Field(key: "charge_status")
    var chargeStatus: String

    @Field(key: "finance_status")
    var financeStatus: String

    @OptionalField(key: "covered_at")
    var coveredAt: Date?

    @OptionalField(key: "reserved_amount")
    var reservedAmount: Double?

    @OptionalParent(key: "charged_ledger_entry_id")
    var chargedLedgerEntry: LedgerEntry?

    /// Set to true when a late cancellation (within 48 h) triggers a full charge.
    /// Nil means no late-cancellation penalty applies.
    @OptionalField(key: "full_charge_applied")
    var fullChargeApplied: Bool?

    /// Instructor-applied per-lesson discount, in pounds, off the undiscounted
    /// (hourlyRateSnapshot × durationMinutes) price. Nil means no discount. When set,
    /// `priceSnapshot` is this lesson's full price minus this amount — every consumer
    /// (payment, late-cancellation charge, confirmed-lesson billing) already reads
    /// priceSnapshot directly, so nothing else needs to know a discount exists.
    @OptionalField(key: "discount_amount")
    var discountAmount: Decimal?

    @OptionalField(key: "discount_reason")
    var discountReason: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    /// Shared pricing formula — the single source of truth for converting a lesson's
    /// duration and an hourly rate into a price, used at booking time and by every
    /// cancellation/charge fallback. Centralized specifically so a rate correction
    /// never again has to be copy-pasted across call sites.
    static func calculatedPrice(durationMinutes: Int, hourlyRate: Decimal) -> Decimal {
        (hourlyRate * Decimal(durationMinutes)) / 60
    }

    /// Creates a LessonFinance row for (lessonID, studentID) if none exists yet, or
    /// reassigns an existing one to the new student — used any time a booking is
    /// attached to a lesson (direct instructor booking, reschedule, swap) so the finance
    /// record always tracks whoever is actually booked on that lesson now, rather than
    /// whoever was booked on it last.
    static func reassignOrCreate(lessonID: UUID, studentID: UUID, on db: Database) async throws {
        if let existing = try await LessonFinance.find(lessonID, on: db) {
            if existing.$student.id != studentID {
                existing.$student.id = studentID
                existing.financeStatus = "not_covered"
                existing.reservedAmount = nil
                existing.coveredAt = nil
                try await existing.save(on: db)
            }
        } else {
            guard let lesson = try await Lesson.find(lessonID, on: db) else { return }
            let durationMinutes = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
            let studentProfile = try await StudentProfile.query(on: db)
                .filter(\.$user.$id == studentID)
                .first()
            let hourlyRate = studentProfile?.hourlyRate ?? 45
            let priceSnapshot = LessonFinance.calculatedPrice(durationMinutes: durationMinutes, hourlyRate: hourlyRate)
            guard let instructorID = try await User.query(on: db)
                .filter(\.$role == "instructor")
                .first()?.requireID()
            else { return }
            let newFinance = LessonFinance(
                lessonID: lessonID,
                studentID: studentID,
                instructorID: instructorID,
                durationMinutes: durationMinutes,
                hourlyRateSnapshot: hourlyRate,
                priceSnapshot: priceSnapshot
            )
            try await newFinance.save(on: db)
        }
    }

    /// Deletes a lesson's LessonFinance row if the lesson no longer has any active
    /// booking — called whenever a booking is moved off a lesson (reschedule/swap), so a
    /// stale finance record pointing at a student who isn't booked on it any more doesn't
    /// linger and later get surfaced as a bogus "needs a charge decision" item.
    static func deleteIfOrphaned(lessonID: UUID, on db: Database) async throws {
        let activeCount = try await Booking.query(on: db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .count()
        guard activeCount == 0 else { return }
        try await LessonFinance.query(on: db)
            .filter(\.$id == lessonID)
            .delete()
    }

    init() {}

    init(
        lessonID: UUID,
        studentID: UUID,
        instructorID: UUID,
        durationMinutes: Int,
        hourlyRateSnapshot: Decimal,
        priceSnapshot: Decimal,
        chargeStatus: String = "not_charged",
        chargedLedgerEntryID: UUID? = nil,
        financeStatus: String = "not_covered",
        coveredAt: Date? = nil,
        reservedAmount: Double? = nil,
        fullChargeApplied: Bool? = nil,
        discountAmount: Decimal? = nil,
        discountReason: String? = nil
    ) {
        self.id = lessonID
        self.$student.id = studentID
        self.$instructor.id = instructorID
        self.durationMinutes = durationMinutes
        self.hourlyRateSnapshot = hourlyRateSnapshot
        self.priceSnapshot = priceSnapshot
        self.chargeStatus = chargeStatus
        self.$chargedLedgerEntry.id = chargedLedgerEntryID
        self.financeStatus = financeStatus
        self.coveredAt = coveredAt
        self.reservedAmount = reservedAmount
        self.fullChargeApplied = fullChargeApplied
        self.discountAmount = discountAmount
        self.discountReason = discountReason
    }
}
//  LessonFinance.swift
//  MSMServer
//
//  Created by Michael Murray on 21/03/2026.
//


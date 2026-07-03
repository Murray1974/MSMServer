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

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

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
        fullChargeApplied: Bool? = nil
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
    }
}
//  LessonFinance.swift
//  MSMServer
//
//  Created by Michael Murray on 21/03/2026.
//


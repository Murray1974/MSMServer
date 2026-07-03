import Vapor
import Fluent

final class LedgerEntry: Model, Content, @unchecked Sendable {
    static let schema = "ledger_entries"

    @ID(key: .id)
    var id: UUID?

    @OptionalParent(key: "student_id")
    var student: User?

    @Parent(key: "instructor_id")
    var instructor: User

    @OptionalParent(key: "lesson_id")
    var lesson: Lesson?

    @Field(key: "type")
    var type: String

    @Field(key: "amount")
    var amount: Decimal

    @OptionalField(key: "payment_method")
    var paymentMethod: String?

    @OptionalField(key: "note")
    var note: String?

    @Field(key: "effective_date")
    var effectiveDate: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalParent(key: "created_by_user_id")
    var createdByUser: User?

    @OptionalField(key: "voided_at")
    var voidedAt: Date?

    @OptionalField(key: "void_reason")
    var voidReason: String?

    init() {}

    init(
        id: UUID? = nil,
        studentID: UUID? = nil,
        instructorID: UUID,
        lessonID: UUID? = nil,
        type: String,
        amount: Decimal,
        paymentMethod: String? = nil,
        note: String? = nil,
        effectiveDate: Date,
        createdByUserID: UUID? = nil
    ) {
        self.id = id
        self.$student.id = studentID
        self.$instructor.id = instructorID
        self.$lesson.id = lessonID
        self.type = type
        self.amount = amount
        self.paymentMethod = paymentMethod
        self.note = note
        self.effectiveDate = effectiveDate
        self.$createdByUser.id = createdByUserID
    }
}
//  LedgerEntry.swift
//  MSMServer
//
//  Created by Michael Murray on 21/03/2026.
//


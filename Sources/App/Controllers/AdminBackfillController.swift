import Vapor
import Fluent

/// One-off instructor utility for backfilling real historical lessons that happened
/// before the app was in full use (e.g. April–July 2026), where the calendar slot
/// may already exist (`existingLessonID`, synced earlier via the normal calendar sync
/// path) but was never actually booked, confirmed, charged, or paid through the app.
///
/// For each entry this creates/reuses a `Lesson`, then a `Booking`, `LessonFinance`,
/// `ConfirmedLesson(status: .attended)`, and a matching charge+payment `LedgerEntry`
/// pair — all dated to the real historical `startsAt`, so the student's balance is
/// unaffected (charge and payment cancel out) while the month's real income is
/// correctly reflected in Business Finance.
///
/// Idempotent: if a Lesson already has any active (non-deleted) Booking, that entry
/// is skipped rather than duplicated — safe to re-run, including after a partial
/// failure.
struct AdminBackfillController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware())
            .grouped("admin", "backfill")
        admin.post("historical-lessons", use: backfillHistoricalLessons)
    }

    struct Entry: Content {
        let studentEmail: String
        let startsAt: Date
        let endsAt: Date
        let existingLessonID: UUID?
    }

    struct Request: Content {
        let hourlyRate: Decimal
        let dryRun: Bool
        let entries: [Entry]
    }

    struct EntryResult: Content {
        let studentEmail: String
        let startsAt: Date
        let outcome: String // "would_create" / "created" / "skipped_already_booked" / "error"
        let detail: String?
        let durationMinutes: Int?
        let price: Decimal?
        let lessonID: UUID?
    }

    struct Response: Content {
        let dryRun: Bool
        let results: [EntryResult]
        let createdCount: Int
        let skippedCount: Int
        let errorCount: Int
        let totalPrice: Decimal
    }

    func backfillHistoricalLessons(_ req: Vapor.Request) async throws -> Response {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else { throw Abort(.forbidden) }
        let instructorID = try instructor.requireID()

        let input = try req.content.decode(Request.self)

        var results: [EntryResult] = []
        var createdCount = 0
        var skippedCount = 0
        var errorCount = 0
        var totalPrice: Decimal = 0

        for entry in input.entries {
            do {
                let email = entry.studentEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let student = try await User.query(on: req.db)
                    .filter(\.$username == email)
                    .filter(\.$role == "student")
                    .first()
                else {
                    results.append(EntryResult(
                        studentEmail: entry.studentEmail, startsAt: entry.startsAt,
                        outcome: "error", detail: "No student account found for this email.",
                        durationMinutes: nil, price: nil, lessonID: nil
                    ))
                    errorCount += 1
                    continue
                }
                let studentID = try student.requireID()

                // Resolve or (if dry run) preview the Lesson this entry attaches to.
                var lesson: Lesson?
                if let existingID = entry.existingLessonID {
                    lesson = try await Lesson.find(existingID, on: req.db)
                    if lesson == nil {
                        results.append(EntryResult(
                            studentEmail: entry.studentEmail, startsAt: entry.startsAt,
                            outcome: "error", detail: "existingLessonID \(existingID) not found.",
                            durationMinutes: nil, price: nil, lessonID: nil
                        ))
                        errorCount += 1
                        continue
                    }
                }

                // Idempotency guard: don't duplicate a slot that's already booked.
                if let existingLesson = lesson, let lessonID = existingLesson.id {
                    let activeBooking = try await Booking.query(on: req.db)
                        .filter(\.$lesson.$id == lessonID)
                        .filter(\.$deletedAt == nil)
                        .first()
                    if activeBooking != nil {
                        results.append(EntryResult(
                            studentEmail: entry.studentEmail, startsAt: entry.startsAt,
                            outcome: "skipped_already_booked", detail: nil,
                            durationMinutes: nil, price: nil, lessonID: lessonID
                        ))
                        skippedCount += 1
                        continue
                    }
                }

                let startsAt = lesson?.startsAt ?? entry.startsAt
                let endsAt = lesson?.endsAt ?? entry.endsAt
                let durationMinutes = max(0, Int(endsAt.timeIntervalSince(startsAt) / 60))
                let price = LessonFinance.calculatedPrice(durationMinutes: durationMinutes, hourlyRate: input.hourlyRate)

                if input.dryRun {
                    results.append(EntryResult(
                        studentEmail: entry.studentEmail, startsAt: startsAt,
                        outcome: "would_create", detail: lesson == nil ? "new Lesson" : "reuse existing Lesson",
                        durationMinutes: durationMinutes, price: price, lessonID: lesson?.id
                    ))
                    createdCount += 1
                    totalPrice += price
                    continue
                }

                let lessonToReuse = lesson
                try await req.db.transaction { db in
                    let resolvedLesson: Lesson
                    if let existing = lessonToReuse {
                        resolvedLesson = existing
                    } else {
                        let newLesson = Lesson(
                            title: "\(student.firstName ?? "") \(student.lastName ?? "")".trimmingCharacters(in: .whitespaces),
                            startsAt: startsAt,
                            endsAt: endsAt,
                            capacity: 1,
                            calendarName: "MSM Backfill",
                            state: "booked"
                        )
                        try await newLesson.save(on: db)
                        resolvedLesson = newLesson
                    }
                    let lessonID = try resolvedLesson.requireID()

                    let booking = Booking(userID: studentID, lessonID: lessonID, paymentStatus: "paid")
                    try await booking.save(on: db)
                    let bookingID = try booking.requireID()

                    if try await LessonFinance.find(lessonID, on: db) == nil {
                        let finance = LessonFinance(
                            lessonID: lessonID,
                            studentID: studentID,
                            instructorID: instructorID,
                            durationMinutes: durationMinutes,
                            hourlyRateSnapshot: input.hourlyRate,
                            priceSnapshot: price,
                            chargeStatus: "charged",
                            financeStatus: "covered",
                            coveredAt: startsAt
                        )
                        try await finance.save(on: db)
                    }

                    let confirmed = ConfirmedLesson(
                        userID: studentID,
                        lessonID: lessonID,
                        bookingID: bookingID,
                        confirmedAt: startsAt,
                        actualStartsAt: startsAt,
                        actualEndsAt: endsAt,
                        notes: "Backfilled from historical calendar export",
                        status: .attended
                    )
                    try await confirmed.save(on: db)

                    let charge = LedgerEntry(
                        studentID: studentID, instructorID: instructorID, lessonID: lessonID,
                        type: "lesson_charge", amount: -price,
                        note: "Backfilled historical lesson", effectiveDate: startsAt,
                        createdByUserID: instructorID
                    )
                    try await charge.save(on: db)

                    let payment = LedgerEntry(
                        studentID: studentID, instructorID: instructorID, lessonID: lessonID,
                        type: "payment", amount: price, paymentMethod: "cash",
                        note: "Backfilled historical lesson — assumed paid in full", effectiveDate: startsAt,
                        createdByUserID: instructorID
                    )
                    try await payment.save(on: db)
                }

                results.append(EntryResult(
                    studentEmail: entry.studentEmail, startsAt: startsAt,
                    outcome: "created", detail: lesson == nil ? "new Lesson" : "reused existing Lesson",
                    durationMinutes: durationMinutes, price: price, lessonID: lesson?.id
                ))
                createdCount += 1
                totalPrice += price
            } catch {
                results.append(EntryResult(
                    studentEmail: entry.studentEmail, startsAt: entry.startsAt,
                    outcome: "error", detail: "\(error)",
                    durationMinutes: nil, price: nil, lessonID: nil
                ))
                errorCount += 1
            }
        }

        return Response(
            dryRun: input.dryRun, results: results,
            createdCount: createdCount, skippedCount: skippedCount, errorCount: errorCount,
            totalPrice: totalPrice
        )
    }
}

import Vapor
import Fluent
import Foundation

struct TestAppointmentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let instructor = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware()).grouped("instructor")
        let student    = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware()).grouped("student")

        // Lightweight student list for the client-side picker
        instructor.get("students", use: listStudents)
        // All tests for a specific student
        instructor.get("students", ":userID", "tests", use: studentTestHistory)

        let tests = instructor.grouped("tests")
        tests.post(use: createTest)
        tests.get("range", use: testsInRange)
        tests.get("cancelled-events", use: cancelledWithEKEvent)
        tests.get(":testID", use: fetchTestByID)
        tests.post(":testID", "withdraw", use: withdrawTest)
        tests.post(":testID", "attend", use: markAttended)
        tests.delete(":testID", use: deleteTest)
        tests.patch(":testID", use: updateTest)
        tests.post(":testID", "result", use: addResult)
        tests.get("results", use: listResults)

        // Instructor: pending student-submitted requests
        let reqs = instructor.grouped("test-requests")
        reqs.get(use: listPendingRequests)
        reqs.post(":testID", "confirm", use: confirmRequest)
        reqs.post(":testID", "reject",  use: rejectRequest)

        // Student: submit a test request + view their tests + cancel/reschedule
        student.post("test-requests", use: submitTestRequest)
        student.get("tests", use: studentTests)
        student.delete("tests", ":testID", use: cancelTest)
        student.post("tests", ":testID", "reschedule", use: rescheduleTest)
    }

    // MARK: - DVSA fault types

    struct DVSAFaultEntry: Content {
        var category: Int   // 1–27 (DVSA DL25 categories)
        var sub: String?    // sub-category name, nil for top-level categories
        var df: Int         // driver/minor faults
        var s: Int          // serious fault (instant fail)
        var d: Int          // dangerous fault (instant fail)
    }

    struct DVSAFaultSheet: Codable {
        var v: Int = 2
        var attemptNumber: Int?
        var etpa: Bool
        var entries: [DVSAFaultEntry]
    }

    // MARK: - Shared DTO

    struct TestAppointmentDTO: Content {
        var id: UUID
        var userID: UUID
        var studentName: String
        var testTime: String
        var testLocation: String?
        var testCentre: String?
        var testRef: String
        var cancelByDate: String
        var startsAt: Date
        var endsAt: Date
        var state: String
        var status: String
        var submittedBy: String
        var ekEventID: String?
        var chargedLedgerEntryID: UUID?
        var examiner: String?
        var outcome: String?
        var faults: [String]?           // legacy free-text; nil for new records
        var attemptNumber: Int?
        var etpa: Bool?
        var faultEntries: [DVSAFaultEntry]?
        var createdAt: Date?
    }

    struct StudentTestDTO: Content {
        var id: UUID?
        var testTime: String
        var testLocation: String?
        var testCentre: String?
        var testRef: String?
        var cancelByDate: String
        var startsAt: Date?
        var endsAt: Date?
        var state: String
        var status: String
        var submittedBy: String
        var examiner: String?
        var outcome: String?
        var faults: [String]?
        var rejectionReason: String?
    }

    private func decodeFaultSheet(_ raw: String?) -> DVSAFaultSheet? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DVSAFaultSheet.self, from: data)
    }

    private func encodeFaultSheet(_ sheet: DVSAFaultSheet) -> String? {
        guard let data = try? JSONEncoder().encode(sheet) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeLegacyFaults(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func dto(from appt: TestAppointment) -> TestAppointmentDTO {
        let sheet = decodeFaultSheet(appt.faults)
        let legacyFaults = sheet == nil ? decodeLegacyFaults(appt.faults) : nil
        return TestAppointmentDTO(
            id: appt.id ?? UUID(),
            userID: appt.$user.id,
            studentName: appt.studentName,
            testTime: appt.testTime,
            testLocation: appt.testLocation,
            testCentre: appt.testCentre,
            testRef: appt.testRef,
            cancelByDate: appt.cancelByDate,
            startsAt: appt.startsAt,
            endsAt: appt.endsAt,
            state: appt.state,
            status: appt.status,
            submittedBy: appt.submittedBy,
            ekEventID: appt.ekEventID,
            chargedLedgerEntryID: appt.$chargedLedgerEntry.id,
            examiner: appt.examiner,
            outcome: appt.outcome,
            faults: legacyFaults,
            attemptNumber: sheet?.attemptNumber,
            etpa: sheet?.etpa,
            faultEntries: sheet?.entries,
            createdAt: appt.createdAt
        )
    }

    // MARK: - GET /instructor/students/:userID/tests

    func studentTestHistory(_ req: Request) async throws -> [TestAppointmentDTO] {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing userID")
        }
        let appts = try await TestAppointment.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$startsAt, .descending)
            .all()
        return appts.map { dto(from: $0) }
    }

    // MARK: - GET /instructor/students

    struct StudentPickerRow: Content {
        var id: UUID
        var username: String
        var displayName: String?
    }

    func listStudents(_ req: Request) async throws -> [StudentPickerRow] {
        let students = try await User.query(on: req.db)
            .filter(\.$role == "student")
            .all()
        return students.compactMap { u in
            guard let id = u.id else { return nil }
            return StudentPickerRow(id: id, username: u.username, displayName: u.displayName)
        }
        .sorted { ($0.displayName ?? $0.username) < ($1.displayName ?? $1.username) }
    }

    // MARK: - POST /instructor/tests

    struct CreateTestInput: Content {
        var userID: UUID
        var studentName: String
        var testTime: String
        var testLocation: String?
        var testCentre: String?
        var testRef: String
        var cancelByDate: String
        var startsAt: Date
        var endsAt: Date
        var ekEventID: String?
    }

    func createTest(_ req: Request) async throws -> TestAppointmentDTO {
        let body = try req.content.decode(CreateTestInput.self)
        guard try await User.find(body.userID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Student not found")
        }
        let clash = try await TestAppointment.query(on: req.db)
            .filter(\.$state != "cancelled")
            .filter(\.$startsAt < body.endsAt)
            .filter(\.$endsAt   > body.startsAt)
            .first()
        if clash != nil {
            throw Abort(.conflict, reason: "A test appointment already exists in this time slot")
        }
        let appt = TestAppointment(
            userID: body.userID,
            studentName: body.studentName,
            testTime: body.testTime,
            testLocation: body.testLocation,
            testCentre: body.testCentre,
            testRef: body.testRef,
            cancelByDate: body.cancelByDate,
            startsAt: body.startsAt,
            endsAt: body.endsAt,
            status: "confirmed",
            submittedBy: "instructor",
            ekEventID: body.ekEventID
        )
        try await appt.save(on: req.db)
        return dto(from: appt)
    }

    // MARK: - GET /instructor/tests/results

    func listResults(_ req: Request) async throws -> [TestAppointmentDTO] {
        let appts = try await TestAppointment.query(on: req.db)
            .filter(\.$state == "attended")
            .filter(\.$outcome != nil)
            .sort(\.$startsAt, .descending)
            .all()
        return appts.map { dto(from: $0) }
    }

    // MARK: - GET /instructor/tests/range

    func testsInRange(_ req: Request) async throws -> [TestAppointmentDTO] {
        struct Filter: Decodable { var from: String; var to: String }
        let filter = try req.query.decode(Filter.self)
        let iso = ISO8601DateFormatter()
        guard let fromDate = iso.date(from: filter.from),
              let toDate   = iso.date(from: filter.to) else {
            throw Abort(.badRequest, reason: "Invalid from/to")
        }
        let appts = try await TestAppointment.query(on: req.db)
            .filter(\.$startsAt >= fromDate)
            .filter(\.$startsAt <= toDate)
            .filter(\.$state != "cancelled")
            .all()
        return appts.map { dto(from: $0) }
    }

    // MARK: - GET /instructor/tests/:testID

    func fetchTestByID(_ req: Request) async throws -> TestAppointmentDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test appointment not found")
        }
        return dto(from: appt)
    }

    // MARK: - POST /instructor/tests/:testID/withdraw

    func withdrawTest(_ req: Request) async throws -> TestAppointmentDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test appointment not found")
        }
        appt.status   = "instructor_withdrawn"
        appt.ekEventID = ""
        try await appt.save(on: req.db)
        req.application.broadcastTestUpdated(studentID: appt.$user.id, status: "instructor_withdrawn", to: .students)
        return dto(from: appt)
    }

    // MARK: - GET /instructor/tests/cancelled-events

    func cancelledWithEKEvent(_ req: Request) async throws -> [TestAppointmentDTO] {
        let since = Date().addingTimeInterval(-60 * 24 * 3600)
        let appts = try await TestAppointment.query(on: req.db)
            .filter(\.$state == "cancelled")
            .filter(\.$startsAt >= since)
            .all()
        return appts.compactMap { appt in
            guard let eid = appt.ekEventID, !eid.isEmpty else { return nil }
            return dto(from: appt)
        }
    }

    // MARK: - POST /instructor/tests/:testID/attend

    func markAttended(_ req: Request) async throws -> TestAppointmentDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test appointment not found")
        }
        guard appt.state == "scheduled" else {
            throw Abort(.conflict, reason: "Test is already \(appt.state)")
        }
        let instructor = try req.auth.require(User.self)
        let instructorID = try instructor.requireID()
        let durationMins = max(0, Int(appt.endsAt.timeIntervalSince(appt.startsAt) / 60))
        let chargeAmount  = (Decimal(45) * Decimal(durationMins)) / Decimal(60)
        let entry = LedgerEntry(
            studentID: appt.$user.id,
            instructorID: instructorID,
            lessonID: nil,
            type: "test_lesson_charge",
            amount: -chargeAmount,
            note: "Test lesson — \(appt.testTime) at \(appt.testLocation ?? "test centre")",
            effectiveDate: Date(),
            createdByUserID: instructorID
        )
        try await entry.save(on: req.db)
        appt.state = "attended"
        appt.$chargedLedgerEntry.id = try entry.requireID()
        try await appt.save(on: req.db)
        return dto(from: appt)
    }

    // MARK: - DELETE /instructor/tests/:testID

    func deleteTest(_ req: Request) async throws -> HTTPStatus {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            return .ok
        }
        appt.state = "cancelled"
        try await appt.save(on: req.db)
        return .ok
    }

    // MARK: - PATCH /instructor/tests/:testID

    struct UpdateTestInput: Content {
        var testRef: String?
        var testLocation: String?
        var testCentre: String?
        var cancelByDate: String?
        var testTime: String?
        var ekEventID: String?
        var startsAt: Date?
        var endsAt: Date?
    }

    func updateTest(_ req: Request) async throws -> TestAppointmentDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test appointment not found")
        }
        let body = try req.content.decode(UpdateTestInput.self)
        if let newStart = body.startsAt, let newEnd = body.endsAt {
            let clash = try await TestAppointment.query(on: req.db)
                .filter(\.$id != testID)
                .filter(\.$state != "cancelled")
                .filter(\.$startsAt < newEnd)
                .filter(\.$endsAt   > newStart)
                .first()
            if clash != nil {
                throw Abort(.conflict, reason: "A test appointment already exists in this time slot")
            }
        }
        if let v = body.testRef      { appt.testRef      = v }
        if let v = body.testLocation { appt.testLocation = v }
        if let v = body.testCentre   { appt.testCentre   = v }
        if let v = body.cancelByDate { appt.cancelByDate = v }
        if let v = body.testTime     { appt.testTime     = v }
        if let v = body.ekEventID    { appt.ekEventID    = v }
        if let v = body.startsAt     { appt.startsAt     = v }
        if let v = body.endsAt       { appt.endsAt       = v }
        try await appt.save(on: req.db)
        return dto(from: appt)
    }

    // MARK: - POST /instructor/tests/:testID/result

    struct AddResultInput: Content {
        var examiner: String
        var outcome: String          // "pass" | "fail"
        var attemptNumber: Int?
        var etpa: Bool?
        var faultEntries: [DVSAFaultEntry]?
    }

    func addResult(_ req: Request) async throws -> TestAppointmentDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test appointment not found")
        }
        let body = try req.content.decode(AddResultInput.self)
        appt.examiner = body.examiner
        appt.outcome  = body.outcome
        let sheet = DVSAFaultSheet(
            attemptNumber: body.attemptNumber,
            etpa: body.etpa ?? false,
            entries: body.faultEntries ?? []
        )
        appt.faults = encodeFaultSheet(sheet)
        try await appt.save(on: req.db)
        return dto(from: appt)
    }

    // MARK: - GET /instructor/test-requests (pending student submissions)

    func listPendingRequests(_ req: Request) async throws -> [TestAppointmentDTO] {
        let appts = try await TestAppointment.query(on: req.db)
            .filter(\.$status == "pending")
            .filter(\.$state != "cancelled")
            .sort(\.$startsAt)
            .all()
        return appts.map { dto(from: $0) }
    }

    // MARK: - POST /instructor/test-requests/:testID/confirm

    func confirmRequest(_ req: Request) async throws -> TestAppointmentDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test request not found")
        }
        appt.status = "confirmed"
        try await appt.save(on: req.db)
        req.application.broadcastTestUpdated(studentID: appt.$user.id, status: "confirmed", to: .students)
        return dto(from: appt)
    }

    // MARK: - POST /instructor/test-requests/:testID/reject

    func rejectRequest(_ req: Request) async throws -> TestAppointmentDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test request not found")
        }
        appt.status = "rejected"
        try await appt.save(on: req.db)
        req.application.broadcastTestUpdated(studentID: appt.$user.id, status: "rejected", to: .students)
        return dto(from: appt)
    }

    // MARK: - POST /student/test-requests

    struct StudentTestRequestInput: Content {
        var testDate: Date       // full date+time of the test (UTC)
        var testTime: String     // HH:mm local display string
        var testCentre: String
        var testLocation: String?
        var applicationRef: String
    }

    func submitTestRequest(_ req: Request) async throws -> StudentTestDTO {
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()
        let body = try req.content.decode(StudentTestRequestInput.self)

        // Snap to nearest hour then ±1h window — same logic as instructor app's testLessonSlot().
        // e.g. test at 08:57 → centre = 09:00 → slot 08:00–10:00.
        var slotCal = Calendar(identifier: .gregorian)
        slotCal.timeZone = TimeZone(secondsFromGMT: 0)!
        var slotComps = slotCal.dateComponents([.year, .month, .day, .hour, .minute], from: body.testDate)
        let slotMinute = slotComps.minute ?? 0
        slotComps.hour   = (slotComps.hour ?? 0) + (slotMinute >= 30 ? 1 : 0)
        slotComps.minute = 0
        slotComps.second = 0
        let centre    = slotCal.date(from: slotComps) ?? body.testDate
        let slotStart = slotCal.date(byAdding: .hour, value: -1, to: centre) ?? body.testDate
        let slotEnd   = slotCal.date(byAdding: .hour, value:  1, to: centre) ?? body.testDate.addingTimeInterval(7200)

        // Cancel-by: 3 days before the actual test time (not the slot start)
        let cal = Calendar(identifier: .gregorian)
        let cancelDate = cal.date(byAdding: .day, value: -3, to: body.testDate) ?? body.testDate
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let cancelByStr = df.string(from: cancelDate)

        // ── Auto-reject rules ────────────────────────────────────────────
        var autoRejectionReason: String? = nil

        // Load the instructor's settings (first user with role "instructor")
        if let instructor = try await User.query(on: req.db).filter(\.$role == "instructor").first() {

            // Rule 1 — minimum weeks notice
            if instructor.testMinWeeksEnabled {
                let minSeconds = Double(instructor.testMinWeeks) * 7 * 24 * 3600
                let gap = body.testDate.timeIntervalSinceNow
                if gap < minSeconds {
                    autoRejectionReason = "This test date is less than \(instructor.testMinWeeks) week\(instructor.testMinWeeks == 1 ? "" : "s") away. Please book further in advance."
                }
            }

            // Rule 2 — clash detection (only if not already rejected)
            if autoRejectionReason == nil && instructor.testAutoRejectClash {
                // Check lessons (MSM or personal) — exclude "available" marker slots
                let clashingLesson = try await Lesson.query(on: req.db)
                    .filter(\.$calendarName != "MSM Available")
                    .filter(\.$startsAt < slotEnd)
                    .filter(\.$endsAt   > slotStart)
                    .first()

                if clashingLesson != nil {
                    let label = clashingLesson?.calendarName == "Personal" ? "a personal appointment" : "a scheduled lesson"
                    autoRejectionReason = "This time slot clashes with \(label) in the instructor's calendar."
                }

                // Check other test appointments (non-cancelled, non-rejected)
                if autoRejectionReason == nil {
                    let clashingTest = try await TestAppointment.query(on: req.db)
                        .filter(\.$state  != "cancelled")
                        .filter(\.$status != "rejected")
                        .filter(\.$status != "auto_rejected")
                        .filter(\.$startsAt < slotEnd)
                        .filter(\.$endsAt   > slotStart)
                        .first()

                    if clashingTest != nil {
                        autoRejectionReason = "This time slot clashes with another test already in the calendar."
                    }
                }
            }
        }
        // ─────────────────────────────────────────────────────────────────

        let finalStatus = autoRejectionReason != nil ? "auto_rejected" : "pending"
        let appt = TestAppointment(
            userID: studentID,
            studentName: student.displayName ?? student.username,
            testTime: body.testTime,
            testLocation: body.testLocation,
            testCentre: body.testCentre,
            testRef: body.applicationRef,
            cancelByDate: cancelByStr,
            startsAt: slotStart,
            endsAt: slotEnd,
            state: finalStatus == "auto_rejected" ? "cancelled" : "scheduled",
            status: finalStatus,
            submittedBy: "student"
        )
        try await appt.save(on: req.db)
        req.application.broadcastTestUpdated(studentID: studentID, status: finalStatus, to: .instructors)
        return studentDTO(from: appt, rejectionReason: autoRejectionReason)
    }

    // MARK: - GET /student/tests

    func studentTests(_ req: Request) async throws -> [StudentTestDTO] {
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()
        let appts = try await TestAppointment.query(on: req.db)
            .filter(\.$user.$id == studentID)
            .filter(\.$state != "cancelled")
            .sort(\.$startsAt)
            .all()
        return appts.map { studentDTO(from: $0) }
    }

    // MARK: - DELETE /student/tests/:testID

    func cancelTest(_ req: Request) async throws -> HTTPStatus {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test appointment not found")
        }
        guard appt.$user.id == studentID else {
            throw Abort(.forbidden, reason: "Not your test appointment")
        }
        appt.state = "cancelled"
        try await appt.save(on: req.db)
        req.application.broadcastTestUpdated(studentID: studentID, status: "cancelled", to: .instructors)
        return .ok
    }

    // MARK: - POST /student/tests/:testID/reschedule

    struct RescheduleTestInput: Content {
        var newTestDate: Date
        var newTestTime: String
        var testCentre: String?
        var testLocation: String?
        var applicationRef: String?
    }

    func rescheduleTest(_ req: Request) async throws -> StudentTestDTO {
        guard let testID = req.parameters.get("testID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing testID")
        }
        let student = try req.auth.require(User.self)
        let studentID = try student.requireID()
        guard let appt = try await TestAppointment.find(testID, on: req.db) else {
            throw Abort(.notFound, reason: "Test appointment not found")
        }
        guard appt.$user.id == studentID else {
            throw Abort(.forbidden, reason: "Not your test appointment")
        }
        guard appt.status == "confirmed" || appt.status == "pending" else {
            throw Abort(.conflict, reason: "Can only reschedule active test appointments")
        }

        let body = try req.content.decode(RescheduleTestInput.self)

        // Cancel the old appointment
        appt.state = "cancelled"
        try await appt.save(on: req.db)

        // Slot-snap the new date (same logic as submitTestRequest)
        var slotCal = Calendar(identifier: .gregorian)
        slotCal.timeZone = TimeZone(secondsFromGMT: 0)!
        var slotComps = slotCal.dateComponents([.year, .month, .day, .hour, .minute], from: body.newTestDate)
        let slotMinute = slotComps.minute ?? 0
        slotComps.hour   = (slotComps.hour ?? 0) + (slotMinute >= 30 ? 1 : 0)
        slotComps.minute = 0; slotComps.second = 0
        let centre    = slotCal.date(from: slotComps) ?? body.newTestDate
        let slotStart = slotCal.date(byAdding: .hour, value: -1, to: centre) ?? body.newTestDate
        let slotEnd   = slotCal.date(byAdding: .hour, value:  1, to: centre) ?? body.newTestDate.addingTimeInterval(7200)

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(secondsFromGMT: 0)
        let cancelByStr = df.string(from: slotCal.date(byAdding: .day, value: -3, to: body.newTestDate) ?? body.newTestDate)

        let newAppt = TestAppointment(
            userID: studentID,
            studentName: student.displayName ?? student.username,
            testTime: body.newTestTime,
            testLocation: body.testLocation ?? appt.testLocation,
            testCentre: body.testCentre ?? appt.testCentre,
            testRef: body.applicationRef ?? appt.testRef,
            cancelByDate: cancelByStr,
            startsAt: slotStart,
            endsAt: slotEnd,
            state: "scheduled",
            status: "pending",
            submittedBy: "student"
        )
        try await newAppt.save(on: req.db)
        req.application.broadcastTestUpdated(studentID: studentID, status: "rescheduled", to: .instructors)
        return studentDTO(from: newAppt)
    }

    // MARK: - Private helpers

    private func studentDTO(from appt: TestAppointment, rejectionReason: String? = nil) -> StudentTestDTO {
        StudentTestDTO(
            id: appt.id,
            testTime: appt.testTime,
            testLocation: appt.testLocation,
            testCentre: appt.testCentre,
            testRef: appt.testRef == "Required" ? nil : appt.testRef,
            cancelByDate: appt.cancelByDate,
            startsAt: appt.startsAt,
            endsAt: appt.endsAt,
            state: appt.state,
            status: appt.status,
            submittedBy: appt.submittedBy,
            examiner: appt.examiner,
            outcome: appt.outcome,
            faults: decodeLegacyFaults(appt.faults),
            rejectionReason: rejectionReason
        )
    }
}


import Vapor
import Fluent

private struct BusinessSummaryQuery: Content {
    let start: String?
    let end: String?
}

struct BusinessLedgerRowView: Content {
    let id: UUID
    let type: String
    let amount: Decimal
    let note: String?
    let effectiveDate: Date
    let createdAt: Date?
}

struct BusinessMonthlyView: Content {
    let month: String
    let income: Decimal
    let expenses: Decimal
    let net: Decimal
}


struct BusinessSummaryView: Content {
    let startDate: Date
    let endDate: Date
    let income: Decimal
    let expenses: Decimal
    let net: Decimal
    let estimatedTax: Decimal
    let takeHome: Decimal
    let cashIn: Decimal
    let cashOut: Decimal
    let cashBalance: Decimal
    let outstandingCredit: Decimal
    let trueAvailableCash: Decimal
    let paymentCount: Int
    let expenseCount: Int
    let recentEntries: [BusinessLedgerRowView]
    let allEntries: [BusinessLedgerRowView]
    let expenseCategories: [String: Decimal]
    let monthlyBreakdown: [BusinessMonthlyView]
}

struct BusinessExpenseExportRow {
    let effectiveDate: Date
    let category: String
    let note: String
    let amount: Decimal
}

struct BusinessLedgerExportRow {
    let effectiveDate: Date
    let type: String
    let category: String
    let note: String
    let amount: Decimal
    let runningBalance: Decimal
}

struct FinanceController {
    func businessSummary(req: Request) async throws -> BusinessSummaryView {
        let instructorID = try req.auth.require(User.self).requireID()
        let query = try req.query.decode(BusinessSummaryQuery.self)

        guard let startDate = parseBusinessDate(query.start) else {
            throw Abort(.badRequest, reason: "Missing or invalid start date")
        }
        guard let rawEndDate = parseBusinessDate(query.end) else {
            throw Abort(.badRequest, reason: "Missing or invalid end date")
        }

        let endDate: Date
        if let endValue = query.end, isDateOnlyBusinessDate(endValue) {
            let calendar = Calendar(identifier: .gregorian)
            let nextDayStart = calendar.date(byAdding: .day, value: 1, to: rawEndDate) ?? rawEndDate
            endDate = nextDayStart.addingTimeInterval(-0.001)
        } else {
            endDate = rawEndDate
        }

        let entries = try await LedgerEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$effectiveDate >= startDate)
            .filter(\.$effectiveDate <= endDate)
            .all()

        let incomeEntries = entries.filter { $0.type == "payment" }
        let expenseEntries = entries.filter { $0.type == "expense" || $0.type.hasPrefix("expense_") }

        let income = incomeEntries.reduce(Decimal.zero) { partial, entry in
            partial + entry.amount
        }

        let expenses = expenseEntries.reduce(Decimal.zero) { partial, entry in
            partial + abs(entry.amount)
        }

        let net = income - expenses

        // Simple UK tax model (basic version)
        let personalAllowance = Decimal(12570)
        let taxableIncome = max(Decimal(0), net - personalAllowance)
        let estimatedTax = taxableIncome * Decimal(0.20)

        let takeHome = net - estimatedTax

        // Cash view (actual money movement)
        let cashIn = incomeEntries.reduce(Decimal.zero) { $0 + $1.amount }
        let cashOut = expenseEntries.reduce(Decimal.zero) { $0 + abs($1.amount) }
        let cashBalance = cashIn - cashOut

        // Outstanding student credit (liability)
        let studentBalances = try await self.studentBalances(req: req)
        let outstandingCredit = studentBalances.reduce(Decimal.zero) { $0 + max($1.currentBalance, 0) }

        let trueAvailableCash = cashBalance - outstandingCredit

        var categoryTotals: [String: Decimal] = [:]

        for entry in expenseEntries {
            let rawType = entry.type
            let category: String
            if rawType.hasPrefix("expense_") {
                category = String(rawType.dropFirst("expense_".count))
            } else {
                category = "other"
            }

            categoryTotals[category, default: 0] += abs(entry.amount)
        }

        let recentEntries = entries
            .sorted {
                let lhs = $0.createdAt ?? $0.effectiveDate
                let rhs = $1.createdAt ?? $1.effectiveDate
                if lhs == rhs {
                    return $0.effectiveDate > $1.effectiveDate
                }
                return lhs > rhs
            }
            .prefix(20)
            .compactMap { entry -> BusinessLedgerRowView? in
                guard let id = entry.id else { return nil }
                return BusinessLedgerRowView(
                    id: id,
                    type: entry.type,
                    amount: entry.amount,
                    note: entry.note,
                    effectiveDate: entry.effectiveDate,
                    createdAt: entry.createdAt
                )
            }

        let allEntries = entries
            .sorted {
                let lhs = $0.createdAt ?? $0.effectiveDate
                let rhs = $1.createdAt ?? $1.effectiveDate
                if lhs == rhs {
                    return $0.effectiveDate > $1.effectiveDate
                }
                return lhs > rhs
            }
            .compactMap { entry -> BusinessLedgerRowView? in
                guard let id = entry.id else { return nil }
                return BusinessLedgerRowView(
                    id: id,
                    type: entry.type,
                    amount: entry.amount,
                    note: entry.note,
                    effectiveDate: entry.effectiveDate,
                    createdAt: entry.createdAt
                )
            }

        let calendar = Calendar(identifier: .gregorian)
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"

        let groupedByMonth = Dictionary(grouping: entries) { entry -> Date in
            let comps = calendar.dateComponents([.year, .month], from: entry.effectiveDate)
            return calendar.date(from: comps) ?? entry.effectiveDate
        }

        let monthlyBreakdown = groupedByMonth
            .map { (date, entries) -> BusinessMonthlyView in
                let income = entries
                    .filter { $0.type == "payment" }
                    .reduce(Decimal.zero) { $0 + $1.amount }

                let expenses = entries
                    .filter { $0.type == "expense" || $0.type.hasPrefix("expense_") }
                    .reduce(Decimal.zero) { $0 + abs($1.amount) }

                return BusinessMonthlyView(
                    month: monthFormatter.string(from: date),
                    income: income,
                    expenses: expenses,
                    net: income - expenses
                )
            }
            .sorted { $0.month < $1.month }

        return BusinessSummaryView(
            startDate: startDate,
            endDate: endDate,
            income: income,
            expenses: expenses,
            net: net,
            estimatedTax: estimatedTax,
            takeHome: takeHome,
            cashIn: cashIn,
            cashOut: cashOut,
            cashBalance: cashBalance,
            outstandingCredit: outstandingCredit,
            trueAvailableCash: trueAvailableCash,
            paymentCount: incomeEntries.count,
            expenseCount: expenseEntries.count,
            recentEntries: recentEntries,
            allEntries: allEntries,
            expenseCategories: categoryTotals,
            monthlyBreakdown: monthlyBreakdown
        )
    }

    func exportExpensesCSV(req: Request) async throws -> Response {
        let instructorID = try req.auth.require(User.self).requireID()
        let query = try req.query.decode(BusinessSummaryQuery.self)

        guard let startDate = parseBusinessDate(query.start) else {
            throw Abort(.badRequest, reason: "Missing or invalid start date")
        }
        guard let rawEndDate = parseBusinessDate(query.end) else {
            throw Abort(.badRequest, reason: "Missing or invalid end date")
        }

        let endDate: Date
        if let endValue = query.end, isDateOnlyBusinessDate(endValue) {
            let calendar = Calendar(identifier: .gregorian)
            let nextDayStart = calendar.date(byAdding: .day, value: 1, to: rawEndDate) ?? rawEndDate
            endDate = nextDayStart.addingTimeInterval(-0.001)
        } else {
            endDate = rawEndDate
        }

        let entries = try await LedgerEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$effectiveDate >= startDate)
            .filter(\.$effectiveDate <= endDate)
            .all()
            .filter { $0.type == "expense" || $0.type.hasPrefix("expense_") }
            .sorted { $0.effectiveDate > $1.effectiveDate }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_GB")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"

        func categoryName(for type: String) -> String {
            if type.hasPrefix("expense_") {
                return String(type.dropFirst("expense_".count))
            }
            return "other"
        }

        func csvEscape(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        let header = "Date,Category,Note,Amount"
        let rows = entries.map { entry in
            let date = dateFormatter.string(from: entry.effectiveDate)
            let category = categoryName(for: entry.type)
            let note = entry.note ?? ""
            let amount = NSDecimalNumber(decimal: abs(entry.amount)).stringValue
            return [
                csvEscape(date),
                csvEscape(category),
                csvEscape(note),
                csvEscape(amount)
            ].joined(separator: ",")
        }

        let csv = ([header] + rows).joined(separator: "\n")

        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "text", subType: "csv")
        response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=expenses.csv")
        response.body = .init(string: csv)
        return response
    }

    func exportLedgerCSV(req: Request) async throws -> Response {
        let instructorID = try req.auth.require(User.self).requireID()
        let query = try req.query.decode(BusinessSummaryQuery.self)

        guard let startDate = parseBusinessDate(query.start) else {
            throw Abort(.badRequest, reason: "Missing or invalid start date")
        }
        guard let rawEndDate = parseBusinessDate(query.end) else {
            throw Abort(.badRequest, reason: "Missing or invalid end date")
        }

        let endDate: Date
        if let endValue = query.end, isDateOnlyBusinessDate(endValue) {
            let calendar = Calendar(identifier: .gregorian)
            let nextDayStart = calendar.date(byAdding: .day, value: 1, to: rawEndDate) ?? rawEndDate
            endDate = nextDayStart.addingTimeInterval(-0.001)
        } else {
            endDate = rawEndDate
        }

        let entries = try await LedgerEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$effectiveDate >= startDate)
            .filter(\.$effectiveDate <= endDate)
            .all()
            .sorted { lhs, rhs in
                if lhs.effectiveDate == rhs.effectiveDate {
                    let lhsCreated = lhs.createdAt ?? lhs.effectiveDate
                    let rhsCreated = rhs.createdAt ?? rhs.effectiveDate
                    return lhsCreated > rhsCreated
                }
                return lhs.effectiveDate > rhs.effectiveDate
            }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_GB")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"

        func categoryName(for entry: LedgerEntry) -> String {
            let type = entry.type
            if type.hasPrefix("expense_") {
                return String(type.dropFirst("expense_".count))
            }
            if type == "expense" {
                return "other"
            }
            if type == "payment" {
                return entry.paymentMethod ?? "payment"
            }
            if type == "lesson_charge" {
                return "lesson_charge"
            }
            return type
        }

        func csvEscape(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        let header = "Date,Type,Category,Note,Amount,Running Balance"
        var runningBalance = Decimal.zero
        let rows = entries.map { entry in
            runningBalance += entry.amount

            let date = dateFormatter.string(from: entry.effectiveDate)
            let type = entry.type
            let category = categoryName(for: entry)
            let note = entry.note ?? ""
            let amount = NSDecimalNumber(decimal: entry.amount).stringValue
            let runningBalanceString = NSDecimalNumber(decimal: runningBalance).stringValue

            return [
                csvEscape(date),
                csvEscape(type),
                csvEscape(category),
                csvEscape(note),
                csvEscape(amount),
                csvEscape(runningBalanceString)
            ].joined(separator: ",")
        }

        let csv = ([header] + rows).joined(separator: "\n")

        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "text", subType: "csv")
        response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=ledger.csv")
        response.body = .init(string: csv)
        return response
    }

    func addPayment(req: Request) async throws -> LedgerEntry {
        let input = try req.content.decode(AddPaymentInput.self)
        let instructorID = try req.auth.require(User.self).requireID()

        let entry = LedgerEntry(
            studentID: input.studentID,
            instructorID: instructorID,
            lessonID: input.lessonID,
            type: "payment",
            amount: input.amount,
            paymentMethod: input.paymentMethod,
            note: input.note,
            effectiveDate: input.effectiveDate,
            createdByUserID: instructorID
        )

        try await entry.save(on: req.db)

        // If the instructor explicitly allocated this payment to a past lesson, mark it covered now.
        if let lessonID = input.lessonID,
           let lf = try await LessonFinance.find(lessonID, on: req.db),
           lf.financeStatus != "charged" {
            lf.financeStatus = "covered"
            lf.coveredAt = Date()
            try await lf.save(on: req.db)
        }

        try await reevaluateCoverageForStudent(input.studentID, on: req.db)
        return entry
    }

    func outstandingLessons(req: Request) async throws -> [OutstandingLessonDTO] {
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing studentID")
        }

        let now = Date()
        let finances = try await LessonFinance.query(on: req.db)
            .filter(\.$student.$id == studentID)
            .filter(\.$financeStatus ~~ ["not_covered", "charge_pending"])
            .all()

        var results: [OutstandingLessonDTO] = []
        for lf in finances {
            guard let lessonID = lf.id,
                  let lesson = try await Lesson.find(lessonID, on: req.db),
                  lesson.startsAt < now else { continue }
            results.append(OutstandingLessonDTO(
                lessonID: lessonID,
                startsAt: lesson.startsAt,
                endsAt: lesson.endsAt,
                amountDue: lf.priceSnapshot,
                financeStatus: lf.financeStatus
            ))
        }
        return results.sorted { $0.startsAt < $1.startsAt }
    }

    struct OutstandingLessonDTO: Content {
        let lessonID: UUID
        let startsAt: Date
        let endsAt: Date
        let amountDue: Decimal
        let financeStatus: String
    }

    func addExpense(req: Request) async throws -> LedgerEntry {
        struct AddExpenseInput: Content {
            let amount: Decimal
            let category: String?
            let note: String?
            let effectiveDate: Date
        }

        let input = try req.content.decode(AddExpenseInput.self)
        let instructorID = try req.auth.require(User.self).requireID()

        // Always store expenses as negative values
        let amount = -abs(input.amount)

        let type: String
        if let category = input.category, category.isEmpty == false {
            type = "expense_\(category.lowercased())"
        } else {
            type = "expense"
        }

        let entry = LedgerEntry(
            studentID: nil,
            instructorID: instructorID,
            lessonID: nil,
            type: type,
            amount: amount,
            paymentMethod: nil,
            note: input.note,
            effectiveDate: input.effectiveDate,
            createdByUserID: instructorID
        )

        try await entry.save(on: req.db)

        return entry
    }

    func deleteExpense(req: Request) async throws -> HTTPStatus {
        let instructorID = try req.auth.require(User.self).requireID()

        guard let expenseID = req.parameters.get("expenseID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid expenseID")
        }

        guard let entry = try await LedgerEntry.find(expenseID, on: req.db) else {
            throw Abort(.notFound, reason: "Expense not found")
        }

        guard entry.$instructor.id == instructorID else {
            throw Abort(.forbidden, reason: "You can only delete your own expense entries")
        }

        guard entry.type == "expense" || entry.type.hasPrefix("expense_") else {
            throw Abort(.badRequest, reason: "Selected ledger entry is not an expense")
        }

        try await entry.delete(on: req.db)
        return .ok
    }

    func updateExpense(req: Request) async throws -> LedgerEntry {
        struct UpdateExpenseInput: Content {
            let amount: Decimal
            let category: String?
            let note: String?
            let effectiveDate: Date
        }

        let instructorID = try req.auth.require(User.self).requireID()

        guard let expenseID = req.parameters.get("expenseID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid expenseID")
        }

        guard let entry = try await LedgerEntry.find(expenseID, on: req.db) else {
            throw Abort(.notFound, reason: "Expense not found")
        }

        guard entry.$instructor.id == instructorID else {
            throw Abort(.forbidden, reason: "You can only update your own expense entries")
        }

        guard entry.type == "expense" || entry.type.hasPrefix("expense_") else {
            throw Abort(.badRequest, reason: "Selected ledger entry is not an expense")
        }

        let input = try req.content.decode(UpdateExpenseInput.self)

        // Always store expenses as negative values
        entry.amount = -abs(input.amount)

        if let category = input.category, category.isEmpty == false {
            entry.type = "expense_\(category.lowercased())"
        } else {
            entry.type = "expense"
        }

        entry.note = input.note
        entry.effectiveDate = input.effectiveDate

        try await entry.save(on: req.db)

        return entry
    }

    func studentTransactions(req: Request) async throws -> [StudentTransactionView] {
        guard let studentID = req.parameters.get("studentID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid studentID")
        }

        let entries = try await LedgerEntry.query(on: req.db)
            .filter(\.$student.$id == studentID)
            .sort(\.$effectiveDate, .descending)
            .all()

        return entries.compactMap { entry in
            guard let id = entry.id else { return nil }
            return StudentTransactionView(
                id: id,
                lessonID: entry.$lesson.id,
                type: entry.type,
                amount: entry.amount,
                paymentMethod: entry.paymentMethod,
                note: entry.note,
                effectiveDate: entry.effectiveDate,
                createdAt: entry.createdAt,
                voidedAt: entry.voidedAt,
                voidReason: entry.voidReason
            )
        }
    }
    func studentBalances(req: Request) async throws -> [StudentBalanceView] {
        let ledgerEntries = try await LedgerEntry.query(on: req.db)
            .with(\.$student)
            .all()

        let lessonFinances = try await LessonFinance.query(on: req.db)
            .with(\.$student)
            .all()

        let ledgerGrouped = Dictionary(grouping: ledgerEntries, by: { $0.$student.id })
        let financeGrouped = Dictionary(grouping: lessonFinances, by: { $0.$student.id })

        let ledgerStudentIDs = Set(ledgerGrouped.keys.compactMap { $0 })
        let financeStudentIDs = Set(financeGrouped.keys.compactMap { $0 })
        let allStudentIDs = ledgerStudentIDs.union(financeStudentIDs)

        var results: [StudentBalanceView] = []
        let now = Date()

        for studentID in allStudentIDs {
            let ledgerForStudent = ledgerGrouped[studentID] ?? []
            let financeForStudent = financeGrouped[studentID] ?? []

            guard let student = ledgerForStudent.first?.student ?? financeForStudent.first?.student else {
                continue
            }

            let firstName = student.firstName?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let lastName = student.lastName?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let fullName = "\(firstName) \(lastName)".trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let displayName = fullName.isEmpty ? student.username : fullName

            let balance = ledgerForStudent.filter { $0.voidedAt == nil }.reduce(Decimal(0)) { partial, entry in
                partial + entry.amount
            }

            let nextBooking = try await Booking.query(on: req.db)
                .filter(\.$user.$id == studentID)
                .with(\.$lesson)
                .filter(\.$deletedAt == nil)
                .all()
                .filter { $0.lesson.startsAt >= now }
                .sorted { $0.lesson.startsAt < $1.lesson.startsAt }
                .first

            let nextLessonID = nextBooking?.$lesson.id
            let nextLessonStartsAt = nextBooking?.lesson.startsAt

            var nextLessonPrice: Decimal? = nil
            var nextLessonFinanceStatus: String? = nil

            if let lessonID = nextLessonID,
               let lessonFinance = try await LessonFinance.find(lessonID, on: req.db) {
                nextLessonPrice = lessonFinance.priceSnapshot
                // Re-evaluate all upcoming lessons in chronological order so credit is
                // always allocated to the earliest lesson first, then reload to get the
                // updated status — reevaluate works on fresh DB instances so the local
                // object would be stale without a reload.
                try await reevaluateCoverageForStudent(studentID, on: req.db)
                nextLessonFinanceStatus = try await LessonFinance.find(lessonID, on: req.db)?.financeStatus
            }

            let nextLessonCovered: Bool
            if let status = nextLessonFinanceStatus {
                nextLessonCovered = status == "covered" || status == "charge_pending" || status == "charged"
            } else if let price = nextLessonPrice {
                nextLessonCovered = balance >= price
            } else {
                nextLessonCovered = balance > 0
            }

            // Outstanding late cancel fees = gross charges minus any waivers already applied.
            let lateCancelCharges = ledgerForStudent.filter { $0.type == "late_cancellation_charge" }
                .reduce(Decimal.zero) { $0 + abs($1.amount) }
            let lateCancelWaivers = ledgerForStudent.filter { $0.type == "fee_waiver" }
                .reduce(Decimal.zero) { $0 + $1.amount }
            let netLateCancelFees = max(Decimal.zero, lateCancelCharges - lateCancelWaivers)
            let lateCancelEntries = ledgerForStudent.filter { $0.type == "late_cancellation_charge" }
            let lateCancelFeesCount = netLateCancelFees > 0 ? lateCancelEntries.count : 0
            let lateCancelFeesTotal = netLateCancelFees

            results.append(
                StudentBalanceView(
                    studentID: studentID,
                    studentName: displayName,
                    currentBalance: balance,
                    nextLessonID: nextLessonID,
                    nextLessonStartsAt: nextLessonStartsAt,
                    nextLessonPrice: nextLessonPrice,
                    nextLessonCovered: nextLessonCovered,
                    nextLessonFinanceStatus: nextLessonFinanceStatus,
                    lateCancelFeesCount: lateCancelFeesCount,
                    lateCancelFeesTotal: lateCancelFeesTotal
                )
            )
        }

        return results.sorted {
            $0.studentName.localizedCaseInsensitiveCompare($1.studentName) == .orderedAscending
        }
    }
    func chargeLesson(req: Request) async throws -> LedgerEntry {
        let instructorID = try req.auth.require(User.self).requireID()
        guard let lessonID = req.parameters.get("lessonID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid lessonID")
        }

        guard let lesson = try await Lesson.find(lessonID, on: req.db) else {
            throw Abort(.notFound, reason: "Lesson not found")
        }

        guard let booking = try await Booking.query(on: req.db)
            .filter(\.$lesson.$id == lessonID)
            .filter(\.$deletedAt == nil)
            .first()
        else {
            throw Abort(.notFound, reason: "No active booking found for lesson")
        }

        let studentID = booking.$user.id

        var lessonFinance = try await LessonFinance.find(lessonID, on: req.db)

        if let existing = lessonFinance, existing.chargeStatus == "charged" {
            throw Abort(.badRequest, reason: "Lesson already charged")
        }

        if lessonFinance == nil {
            let durationMinutes = max(0, Int(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 60))
            let defaultHourlyRate = Decimal(45)
            let priceSnapshot = (defaultHourlyRate * Decimal(durationMinutes)) / Decimal(60)

            let newLessonFinance = LessonFinance(
                lessonID: lessonID,
                studentID: studentID,
                instructorID: instructorID,
                durationMinutes: durationMinutes,
                hourlyRateSnapshot: defaultHourlyRate,
                priceSnapshot: priceSnapshot,
                chargeStatus: "not_charged",
                chargedLedgerEntryID: nil,
                financeStatus: "not_covered",
                coveredAt: nil,
                reservedAmount: nil
            )
            try await newLessonFinance.save(on: req.db)
            lessonFinance = newLessonFinance
        }

        let ledgerEntry = LedgerEntry(
            studentID: studentID,
            instructorID: instructorID,
            lessonID: lessonID,
            type: "lesson_charge",
            amount: -(lessonFinance?.priceSnapshot ?? Decimal.zero),
            paymentMethod: nil,
            note: nil,
            effectiveDate: lesson.startsAt,
            createdByUserID: instructorID
        )

        try await ledgerEntry.save(on: req.db)

        lessonFinance?.chargeStatus = "charged"
        lessonFinance?.financeStatus = "charged"
        lessonFinance?.coveredAt = lessonFinance?.coveredAt ?? Date()
        lessonFinance?.reservedAmount = nil
        lessonFinance?.$chargedLedgerEntry.id = try ledgerEntry.requireID()
        try await lessonFinance?.save(on: req.db)

        if let lessonFinance {
            try await evaluateCoverage(for: lessonFinance, on: req.db)
        }

        return ledgerEntry
    }
    // MARK: - Coverage Helpers

    func availableCredit(
        for studentID: UUID,
        excluding lessonID: UUID?,
        on db: Database
    ) async throws -> Decimal {

        let ledger = try await LedgerEntry.query(on: db)
            .filter(\.$student.$id == studentID)
            .all()

        let balance = ledger.filter { $0.voidedAt == nil }.reduce(Decimal(0)) { $0 + $1.amount }

        let reservedLessons = try await LessonFinance.query(on: db)
            .filter(\.$student.$id == studentID)
            .group(.or) { group in
                group.filter(\.$financeStatus == "covered")
                group.filter(\.$financeStatus == "charge_pending")
            }
            .all()

        // Fetch the start times for reserved lessons so we can exclude past ones.
        // A lesson that has already started should not block credit for future lessons.
        let now = Date()
        let reservedLessonIDs = reservedLessons.compactMap { $0.id }
        let upcomingLessonIDs: Set<UUID>
        if reservedLessonIDs.isEmpty {
            upcomingLessonIDs = []
        } else {
            let upcomingLessons = try await Lesson.query(on: db)
                .filter(\.$id ~~ reservedLessonIDs)
                .filter(\.$startsAt > now)
                .all()
            upcomingLessonIDs = Set(upcomingLessons.compactMap { $0.id })
        }

        let reservedTotal = reservedLessons
            .filter { lf in
                guard let lid = lf.id else { return false }
                if let lessonID, lid == lessonID { return false }
                return upcomingLessonIDs.contains(lid)
            }
            .reduce(Decimal(0)) { partial, lf in
                partial + Decimal(lf.reservedAmount ?? 0)
            }

        return balance - reservedTotal
    }


    /// Re-evaluates credit coverage for all upcoming lessons for a student in
    /// chronological order so that the earliest lesson always gets first claim on
    /// the available balance. Call this whenever the student's balance changes
    /// (payment added, booking created/cancelled).
    func reevaluateCoverageForStudent(_ studentID: UUID, on db: Database) async throws {
        let now = Date()

        let lessonFinances = try await LessonFinance.query(on: db)
            .filter(\.$student.$id == studentID)
            .all()
            .filter { $0.chargeStatus != "charged" && $0.financeStatus != "charged" }

        guard !lessonFinances.isEmpty else { return }

        let lessonIDs = lessonFinances.compactMap { $0.id }
        let upcomingLessons = try await Lesson.query(on: db)
            .filter(\.$id ~~ lessonIDs)
            .filter(\.$startsAt > now)
            .all()

        let startMap: [UUID: Date] = Dictionary(uniqueKeysWithValues: upcomingLessons.compactMap {
            guard let id = $0.id else { return nil }
            return (id, $0.startsAt)
        })

        let upcomingFinances = lessonFinances.filter { startMap[$0.id ?? UUID()] != nil }
        guard !upcomingFinances.isEmpty else { return }

        // Clear all reservations first so earlier lessons don't see stale reserved amounts
        // from later lessons when we re-evaluate in order.
        for lf in upcomingFinances {
            lf.financeStatus = "not_covered"
            lf.reservedAmount = nil
            lf.coveredAt = nil
            try await lf.save(on: db)
        }

        // Re-evaluate in chronological order — earliest lesson gets first claim on credit.
        let sorted = upcomingFinances.sorted {
            (startMap[$0.id ?? UUID()] ?? .distantFuture) < (startMap[$1.id ?? UUID()] ?? .distantFuture)
        }
        for lf in sorted {
            try await evaluateCoverage(for: lf, on: db)
        }
    }

    func evaluateCoverage(
        for lessonFinance: LessonFinance,
        on db: Database
    ) async throws {

        let studentID = lessonFinance.$student.id
        guard let lessonID = lessonFinance.id else { return }

        if lessonFinance.chargeStatus == "charged" || lessonFinance.financeStatus == "charged" {
            lessonFinance.financeStatus = "charged"
            lessonFinance.reservedAmount = nil
            lessonFinance.coveredAt = lessonFinance.coveredAt ?? Date()
            try await lessonFinance.save(on: db)
            return
        }

        guard let lesson = try await Lesson.find(lessonID, on: db) else {
            return
        }

        let now = Date()
        let fortyEightHours: TimeInterval = 48 * 60 * 60
        let windowStart = now.addingTimeInterval(fortyEightHours)
        let isWithinChargeWindow = lesson.startsAt <= windowStart


        let available = try await availableCredit(
            for: studentID,
            excluding: lessonID,
            on: db
        )

        if available >= lessonFinance.priceSnapshot {
            lessonFinance.financeStatus = isWithinChargeWindow ? "charge_pending" : "covered"
            lessonFinance.coveredAt = Date()
            lessonFinance.reservedAmount = NSDecimalNumber(decimal: lessonFinance.priceSnapshot).doubleValue
        } else {
            lessonFinance.financeStatus = "not_covered"
            lessonFinance.coveredAt = nil
            lessonFinance.reservedAmount = nil
        }
        try await lessonFinance.save(on: db)
    }

    // MARK: - POST /instructor/finance/ledger/:entryID/void

    func voidEntry(_ req: Request) async throws -> HTTPStatus {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can void entries.")
        }
        let instructorID = try instructor.requireID()

        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing entry ID.")
        }

        struct VoidInput: Content { let reason: String }
        let input = try req.content.decode(VoidInput.self)
        guard !input.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "A reason is required to void an entry.")
        }

        guard let entry = try await LedgerEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound, reason: "Ledger entry not found.")
        }
        guard entry.$instructor.id == instructorID else {
            throw Abort(.forbidden, reason: "You can only void your own ledger entries.")
        }
        guard entry.voidedAt == nil else {
            throw Abort(.conflict, reason: "This entry has already been voided.")
        }

        entry.voidedAt = Date()
        entry.voidReason = input.reason
        try await entry.save(on: req.db)

        if let studentID = entry.$student.id {
            try await reevaluateCoverageForStudent(studentID, on: req.db)
        }

        req.logger.notice("[Finance] Entry \(entryID) voided by \(instructor.username) — reason: \(input.reason)")
        return .ok
    }

    // MARK: - POST /instructor/finance/ledger/:entryID/refund

    func refundEntry(_ req: Request) async throws -> LedgerEntry {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can issue refunds.")
        }
        let instructorID = try instructor.requireID()

        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing entry ID.")
        }

        struct RefundInput: Content {
            let reason: String
            let amount: Decimal?
        }
        let input = try req.content.decode(RefundInput.self)
        guard !input.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "A reason is required to issue a refund.")
        }

        guard let original = try await LedgerEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound, reason: "Ledger entry not found.")
        }
        guard original.$instructor.id == instructorID else {
            throw Abort(.forbidden, reason: "You can only refund your own ledger entries.")
        }
        guard let studentID = original.$student.id else {
            throw Abort(.unprocessableEntity, reason: "Ledger entry has no student — cannot refund.")
        }

        let refundAmount = abs(input.amount ?? original.amount)
        let refund = LedgerEntry(
            studentID: studentID,
            instructorID: instructorID,
            lessonID: original.$lesson.id,
            type: "refund",
            amount: refundAmount,
            paymentMethod: nil,
            note: input.reason,
            effectiveDate: Date(),
            createdByUserID: instructorID
        )
        try await refund.save(on: req.db)
        try await reevaluateCoverageForStudent(studentID, on: req.db)

        req.logger.notice("[Finance] Refund of £\(refundAmount) issued by \(instructor.username) for student \(studentID) — reason: \(input.reason)")
        return refund
    }

    private func isDateOnlyBusinessDate(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 10 else { return false }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        return formatter.date(from: trimmed) != nil
    }

    private func parseBusinessDate(_ value: String?) -> Date? {
        guard let value, value.isEmpty == false else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]
        if let date = isoFormatterNoFraction.date(from: value) {
            return date
        }

        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.locale = Locale(identifier: "en_GB")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: value)
    }

    // MARK: - POST /instructor/ledger/:entryID/waive

    /// Waives a late cancellation charge by creating a matching positive `fee_waiver`
    /// ledger entry.  Idempotent: a second call for the same charge returns 409.
    func waiveFee(_ req: Request) async throws -> LedgerEntry {
        let instructor = try req.auth.require(User.self)
        guard instructor.role == "instructor" else {
            throw Abort(.forbidden, reason: "Only instructors can waive fees.")
        }
        let instructorID = try instructor.requireID()

        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing entry ID.")
        }

        guard let original = try await LedgerEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound, reason: "Ledger entry not found.")
        }

        guard original.type == "late_cancellation_charge" else {
            throw Abort(.badRequest, reason: "Only late_cancellation_charge entries can be waived.")
        }

        guard let studentID = original.$student.id else {
            throw Abort(.unprocessableEntity, reason: "Ledger entry has no student — cannot waive.")
        }

        // Idempotency: the waiver note embeds the original entry ID.
        let waiverNote = "Fee waiver — charge \(entryID.uuidString)"
        let existing = try await LedgerEntry.query(on: req.db)
            .filter(\.$type == "fee_waiver")
            .filter(\.$note == waiverNote)
            .first()
        guard existing == nil else {
            throw Abort(.conflict, reason: "This late cancellation fee has already been waived.")
        }

        let waiver = LedgerEntry(
            studentID: studentID,
            instructorID: instructorID,
            lessonID: original.$lesson.id,
            type: "fee_waiver",
            amount: abs(original.amount),
            note: waiverNote,
            effectiveDate: Date(),
            createdByUserID: instructorID
        )
        try await waiver.save(on: req.db)

        req.logger.notice("[Finance] ✅ Fee waived by \(instructor.username) for student \(studentID) — original entry \(entryID)")
        return waiver
    }

    // MARK: - GET /instructor/finance/week-total?from=&to=
    // Returns { "earned": Decimal, "expected": Decimal }
    //   earned   — lessons that have already started with priceSnapshot > 0
    //   expected — all lessons in the range with priceSnapshot > 0 (including future)
    func weekTotal(req: Request) async throws -> Response {
        struct Filter: Decodable { var from: String; var to: String }
        let filter = try req.query.decode(Filter.self)
        let iso = ISO8601DateFormatter()
        guard let fromDate = iso.date(from: filter.from),
              let toDate   = iso.date(from: filter.to) else {
            throw Abort(.badRequest, reason: "Invalid from/to parameters")
        }

        let now = Date()
        let lessons = try await Lesson.query(on: req.db)
            .filter(\.$startsAt >= fromDate)
            .filter(\.$startsAt <= toDate)
            .all()

        // Only count lessons that have at least one active (non-deleted) booking.
        // Cancelled lessons leave their LessonFinance record behind, so without
        // this filter they'd inflate the expected total.
        // Restrict to bookings within a 90-day look-back window to avoid loading
        // the entire bookings table on every request.
        let ninetyDaysAgo = fromDate.addingTimeInterval(-90 * 24 * 60 * 60)
        let activeBookingLessonIDs: Set<UUID> = try await {
            let bookings = try await Booking.query(on: req.db)
                .filter(\.$deletedAt == nil)
                .join(parent: \Booking.$lesson)
                .filter(Lesson.self, \.$startsAt >= ninetyDaysAgo)
                .all()
            return Set(bookings.map { $0.$lesson.id })
        }()

        var earned: Decimal = 0
        var expected: Decimal = 0
        for lesson in lessons {
            guard let lessonID = lesson.id,
                  activeBookingLessonIDs.contains(lessonID),
                  let lf = try await LessonFinance.find(lessonID, on: req.db) else { continue }
            // Expected: recalculate from duration × rate — independent of priceSnapshot
            // which can be stale or inflated by credit payments.
            let durationHours = Decimal(lesson.endsAt.timeIntervalSince(lesson.startsAt) / 3600.0)
            let correctPrice = durationHours * lf.hourlyRateSnapshot
            expected += correctPrice
            // Earned: lessons that have already started, using stored priceSnapshot
            // (what was actually charged). Fall back to correctPrice if snapshot is 0.
            if lesson.startsAt <= now {
                earned += lf.priceSnapshot > 0 ? lf.priceSnapshot : correctPrice
            }
        }

        let body = try JSONEncoder().encode(["earned": earned, "expected": expected])
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: body))
    }
}

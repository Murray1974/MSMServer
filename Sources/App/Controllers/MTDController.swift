import Vapor
import Fluent
import Foundation

// MARK: - DTOs

struct MTDQuarterRow: Content {
    let index: Int
    let label: String
    let startDate: Date
    let endDate: Date
    let deadline: Date
    let income: Decimal
    let actualCostExpenses: Decimal
    let simplifiedMileageAllowance: Decimal
    let netProfit: Decimal
    let estimatedTax: Decimal
}

struct MTDQuartersResponse: Content {
    let taxYear: Int
    let taxYearLabel: String
    let vehicleCostMethod: String?
    let isDualControlVehicle: Bool?
    let quarters: [MTDQuarterRow]
}

struct VehicleCostMethodView: Content {
    let method: String?
    let isDualControlVehicle: Bool?
}

struct SetVehicleCostMethodRequest: Content {
    let method: String
}

struct SetDualControlVehicleRequest: Content {
    let isDualControlVehicle: Bool
}

/// Making Tax Digital support — quarterly income/expense summaries matching HMRC's standard
/// update periods, a vehicle-cost-method toggle (actual costs vs simplified mileage — HMRC
/// only allows one per vehicle), and a per-quarter CSV export. Deliberately does not talk to
/// HMRC's own API (OAuth/fraud-prevention headers/software recognition) — the CSV export is
/// the practical bridge to existing cheap bridging software. See
/// `peaceful-meandering-whisper.md` for the full rationale.
struct MTDController {

    // MARK: - GET /instructor/mtd/quarters?taxYear=

    func quarters(req: Request) async throws -> MTDQuartersResponse {
        let user = try req.auth.require(User.self)
        let instructorID = try user.requireID()

        let calendar = Self.londonCalendar()
        let taxYear = req.query[Int.self, at: "taxYear"] ?? Self.currentTaxYearStartYear(calendar: calendar)

        let boundaries = Self.quarterBoundaries(taxYearStartYear: taxYear, calendar: calendar)
        let taxYearStart = boundaries[0].start
        let taxYearEnd = boundaries[3].end

        // Fetch everything for the whole tax year once, then slice per quarter in memory —
        // same pattern FinanceController.taxTrend/monthlyTaxBreakdown already use.
        let incomeEntries = try await LedgerEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$type == "payment")
            .filter(\.$effectiveDate >= taxYearStart)
            .filter(\.$effectiveDate <= taxYearEnd)
            .filter(\.$voidedAt == nil)
            .all()

        let expenseEntries = try await ExpenseEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$expenseDate >= taxYearStart)
            .filter(\.$expenseDate <= taxYearEnd)
            .filter(\.$isBusinessUse == true)
            .all()

        // MileageEntry has no instructor relationship anywhere in the app (single-instructor
        // assumption baked into MileageController) — matched here deliberately rather than
        // introducing scoping this feature doesn't otherwise have.
        let mileageEntries = try await MileageEntry.query(on: req.db)
            .filter(\.$date >= taxYearStart)
            .filter(\.$date <= taxYearEnd)
            .all()

        func cumulativeIncome(asOf date: Date) -> Decimal {
            incomeEntries.filter { $0.effectiveDate <= date }.reduce(Decimal.zero) { $0 + $1.amount }
        }
        func cumulativeActualExpenses(asOf date: Date) -> Decimal {
            expenseEntries
                .filter { $0.expenseDate <= date }
                .reduce(Decimal.zero) { $0 + $1.amount * Decimal($1.businessUsePercent) / 100 }
        }
        func cumulativeMileageAllowance(asOf date: Date) -> Decimal {
            let miles = mileageEntries.filter { $0.date <= date }.reduce(0.0) { $0 + $1.miles }
            return Decimal(Self.hmrcMileageAllowance(for: miles))
        }

        let method = user.vehicleCostMethod
        func cumulativeNet(asOf date: Date) -> Decimal {
            let expenses = method == "simplified_mileage" ? cumulativeMileageAllowance(asOf: date) : cumulativeActualExpenses(asOf: date)
            return cumulativeIncome(asOf: date) - expenses
        }

        var previousIncome = Decimal.zero
        var previousActual = Decimal.zero
        var previousMileage = Decimal.zero
        var previousTax = TaxEstimator.estimate(onNet: cumulativeNet(asOf: taxYearStart.addingTimeInterval(-1)))

        var rows: [MTDQuarterRow] = []
        for boundary in boundaries {
            let cumIncome = cumulativeIncome(asOf: boundary.end)
            let cumActual = cumulativeActualExpenses(asOf: boundary.end)
            let cumMileage = cumulativeMileageAllowance(asOf: boundary.end)
            let cumTax = TaxEstimator.estimate(onNet: cumulativeNet(asOf: boundary.end))

            let quarterIncome = cumIncome - previousIncome
            let quarterActual = cumActual - previousActual
            let quarterMileage = cumMileage - previousMileage
            let quarterTax = cumTax - previousTax
            let quarterExpensesUnderActiveMethod = method == "simplified_mileage" ? quarterMileage : quarterActual

            rows.append(MTDQuarterRow(
                index: boundary.index,
                label: boundary.label,
                startDate: boundary.start,
                endDate: boundary.end,
                deadline: boundary.deadline,
                income: quarterIncome,
                actualCostExpenses: quarterActual,
                simplifiedMileageAllowance: quarterMileage,
                netProfit: quarterIncome - quarterExpensesUnderActiveMethod,
                estimatedTax: quarterTax
            ))

            previousIncome = cumIncome
            previousActual = cumActual
            previousMileage = cumMileage
            previousTax = cumTax
        }

        return MTDQuartersResponse(
            taxYear: taxYear,
            taxYearLabel: "\(taxYear)/\(String(format: "%02d", (taxYear + 1) % 100))",
            vehicleCostMethod: method,
            isDualControlVehicle: user.isDualControlVehicle,
            quarters: rows
        )
    }

    // MARK: - Vehicle cost method

    func getVehicleCostMethod(req: Request) async throws -> VehicleCostMethodView {
        let user = try req.auth.require(User.self)
        return VehicleCostMethodView(method: user.vehicleCostMethod, isDualControlVehicle: user.isDualControlVehicle)
    }

    func setVehicleCostMethod(req: Request) async throws -> VehicleCostMethodView {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(SetVehicleCostMethodRequest.self)
        guard ["actual", "simplified_mileage"].contains(body.method) else {
            throw Abort(.badRequest, reason: "method must be 'actual' or 'simplified_mileage'")
        }
        user.vehicleCostMethod = body.method
        try await user.save(on: req.db)
        return VehicleCostMethodView(method: user.vehicleCostMethod, isDualControlVehicle: user.isDualControlVehicle)
    }

    func setDualControlVehicle(req: Request) async throws -> VehicleCostMethodView {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(SetDualControlVehicleRequest.self)
        user.isDualControlVehicle = body.isDualControlVehicle
        try await user.save(on: req.db)
        return VehicleCostMethodView(method: user.vehicleCostMethod, isDualControlVehicle: user.isDualControlVehicle)
    }

    // MARK: - GET /instructor/mtd/quarters/:index/export?taxYear=

    func exportQuarterCSV(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let instructorID = try user.requireID()

        guard let indexParam = req.parameters.get("index", as: Int.self), (1...4).contains(indexParam) else {
            throw Abort(.badRequest, reason: "index must be 1-4")
        }

        let calendar = Self.londonCalendar()
        let taxYear = req.query[Int.self, at: "taxYear"] ?? Self.currentTaxYearStartYear(calendar: calendar)
        let boundary = Self.quarterBoundaries(taxYearStartYear: taxYear, calendar: calendar)[indexParam - 1]

        let incomeEntries = try await LedgerEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$type == "payment")
            .filter(\.$effectiveDate >= boundary.start)
            .filter(\.$effectiveDate <= boundary.end)
            .filter(\.$voidedAt == nil)
            .all()
            .sorted { $0.effectiveDate < $1.effectiveDate }

        let expenseEntries = try await ExpenseEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$expenseDate >= boundary.start)
            .filter(\.$expenseDate <= boundary.end)
            .filter(\.$isBusinessUse == true)
            .all()
            .sorted { $0.expenseDate < $1.expenseDate }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_GB")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"

        func csvEscape(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        var rows: [String] = []
        for entry in incomeEntries {
            let amount = NSDecimalNumber(decimal: entry.amount).stringValue
            rows.append([
                csvEscape(dateFormatter.string(from: entry.effectiveDate)),
                csvEscape("Income"),
                csvEscape(entry.paymentMethod ?? "payment"),
                csvEscape(entry.note ?? ""),
                csvEscape(amount)
            ].joined(separator: ","))
        }
        for entry in expenseEntries {
            let claimable = entry.amount * Decimal(entry.businessUsePercent) / 100
            let amount = NSDecimalNumber(decimal: -claimable).stringValue
            rows.append([
                csvEscape(dateFormatter.string(from: entry.expenseDate)),
                csvEscape("Expense"),
                csvEscape(HMRCCategoryMapping.hmrcCategory(for: entry.category)),
                csvEscape(entry.note ?? entry.vendor ?? ""),
                csvEscape(amount)
            ].joined(separator: ","))
        }

        let header = "Date,Type,HMRC Category,Note,Amount"
        let csv = ([header] + rows).joined(separator: "\n")

        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "text", subType: "csv")
        response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=mtd-\(taxYear)-q\(indexParam).csv")
        response.body = .init(string: csv)
        return response
    }

    // MARK: - Quarter boundary math

    struct QuarterBoundary {
        let index: Int
        let label: String
        let start: Date
        /// Inclusive end-of-day (23:59:59.999) on the quarter's last day.
        let end: Date
        let deadline: Date
    }

    static func londonCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        return calendar
    }

    static func currentTaxYearStartYear(calendar: Calendar) -> Int {
        let now = Date()
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return (month > 4 || (month == 4 && day >= 6)) ? year : year - 1
    }

    /// Standard MTD quarters (6 Apr–5 Jul, 6 Jul–5 Oct, 6 Oct–5 Jan, 6 Jan–5 Apr) for the tax
    /// year starting 6 April `taxYearStartYear`. Deadline = 7th of the month immediately after
    /// the quarter ends — confirmed directly against HMRC-sourced material for Q1 (7 Aug) and
    /// Q2 (7 Nov); the same pattern matches third-party listings for Q3/Q4 (7 Feb, 7 May) but
    /// was not found on a definitive gov.uk table during research. Re-verify on gov.uk before
    /// relying on this for real penalty-relevant reminders.
    static func quarterBoundaries(taxYearStartYear y: Int, calendar: Calendar) -> [QuarterBoundary] {
        let defs: [(label: String, startMonth: Int, startYear: Int, endMonth: Int, endDay: Int, endYear: Int, deadlineMonth: Int, deadlineYear: Int)] = [
            ("Q1: 6 Apr \u{2013} 5 Jul", 4, y, 7, 5, y, 8, y),
            ("Q2: 6 Jul \u{2013} 5 Oct", 7, y, 10, 5, y, 11, y),
            ("Q3: 6 Oct \u{2013} 5 Jan", 10, y, 1, 5, y + 1, 2, y + 1),
            ("Q4: 6 Jan \u{2013} 5 Apr", 1, y + 1, 4, 5, y + 1, 5, y + 1)
        ]

        return defs.enumerated().map { offset, def in
            var startComps = DateComponents(); startComps.year = def.startYear; startComps.month = def.startMonth; startComps.day = 6
            var endComps = DateComponents(); endComps.year = def.endYear; endComps.month = def.endMonth; endComps.day = def.endDay
            var deadlineComps = DateComponents(); deadlineComps.year = def.deadlineYear; deadlineComps.month = def.deadlineMonth; deadlineComps.day = 7

            let start = calendar.date(from: startComps) ?? Date()
            let rawEnd = calendar.date(from: endComps) ?? Date()
            let nextDayStart = calendar.date(byAdding: .day, value: 1, to: rawEnd) ?? rawEnd
            let end = nextDayStart.addingTimeInterval(-0.001)
            let deadline = calendar.date(from: deadlineComps) ?? Date()

            return QuarterBoundary(index: offset + 1, label: def.label, start: start, end: end, deadline: deadline)
        }
    }

    /// 45p/mile for first 10,000 miles, 25p/mile thereafter — must match
    /// `MileageController.hmrcAllowance` exactly; both compute the same HMRC rule.
    static func hmrcMileageAllowance(for miles: Double) -> Double {
        miles <= 10_000 ? miles * 0.45 : 10_000 * 0.45 + (miles - 10_000) * 0.25
    }
}

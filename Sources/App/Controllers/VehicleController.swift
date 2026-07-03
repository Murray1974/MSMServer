import Vapor
import Fluent
import Foundation

struct VehicleController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // ── DTOs ─────────────────────────────────────────────────────────────────────

    struct VehicleLogRow: Content {
        let id: UUID
        let logDate: Date
        let odometer: Int?
        let tyrePressureChecked: Bool
        let serviceDate: Date?
        let fuelLitres: Double?
        let lastMOTDate: Date?
        let motExpiryDate: Date?
        let notes: String?
        let createdAt: Date?
    }

    struct VehicleAlert: Content {
        let type: String      // "mot" | "service_date" | "service_mileage"
        let severity: String  // "urgent" | "warning"
        let message: String
        let daysUntil: Int?
        let milesUntil: Int?
    }

    struct VehicleStatusResponse: Content {
        let latestLog: VehicleLogRow?
        let lastServiceLog: VehicleLogRow?
        let nextServiceDate: Date?
        let nextServiceMileage: Int?
        let daysSinceLastService: Int?
        let milesSinceLastService: Int?
        let motExpiryDate: Date?
        let lastMOTDate: Date?
        let alerts: [VehicleAlert]
    }

    struct ExpenseRow: Content {
        let id: UUID
        let amount: Double
        let category: String
        let note: String?
        let expenseDate: Date
        let isBusinessUse: Bool
        let mileage: Int?
        let hasReceipt: Bool
        let createdAt: Date?
    }

    struct ExpenseSummaryResponse: Content {
        let year: Int
        let totalByCategory: [String: Double]
        let totalBusiness: Double
        let totalPersonal: Double
        let grandTotal: Double
        let expenseCount: Int
    }

    // ── POST /instructor/vehicle/log ─────────────────────────────────────────────

    func logVehicleStatus(req: Request) async throws -> VehicleLogRow {
        struct LogInput: Content {
            let logDate: Date?
            let odometer: Int?
            let tyrePressureChecked: Bool?
            let serviceDate: Date?
            let fuelLitres: Double?
            let lastMOTDate: Date?
            let motExpiryDate: Date?
            let notes: String?
        }

        let instructorID = try req.auth.require(User.self).requireID()
        let input = try req.content.decode(LogInput.self)

        let log = VehicleLog(
            instructorID:        instructorID,
            logDate:             input.logDate ?? Date(),
            odometer:            input.odometer,
            tyrePressureChecked: input.tyrePressureChecked ?? false,
            serviceDate:         input.serviceDate,
            fuelLitres:          input.fuelLitres.map { Decimal($0) },
            lastMOTDate:         input.lastMOTDate,
            motExpiryDate:       input.motExpiryDate,
            notes:               input.notes
        )
        try await log.save(on: req.db)
        return try toLogRow(log)
    }

    // ── GET /instructor/vehicle/latest-log ───────────────────────────────────────

    func getVehicleStatus(req: Request) async throws -> VehicleStatusResponse {
        let instructorID = try req.auth.require(User.self).requireID()
        return try await buildStatus(instructorID: instructorID, db: req.db)
    }

    // ── GET /instructor/vehicle/alerts ───────────────────────────────────────────

    func getAlerts(req: Request) async throws -> [VehicleAlert] {
        let instructorID = try req.auth.require(User.self).requireID()
        let status = try await buildStatus(instructorID: instructorID, db: req.db)
        return status.alerts
    }

    // ── GET /instructor/vehicle/logs ─────────────────────────────────────────────

    func getVehicleLogs(req: Request) async throws -> [VehicleLogRow] {
        let instructorID = try req.auth.require(User.self).requireID()
        let logs = try await VehicleLog.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$logDate, .descending)
            .limit(50)
            .all()
        return try logs.map { try toLogRow($0) }
    }

    // ── POST /instructor/vehicle/expenses ────────────────────────────────────────
    // Accepts multipart/form-data (photo optional)
    // wasMOT=true → auto-creates a VehicleLog with lastMOTDate + motExpiryDate

    func createExpense(req: Request) async throws -> ExpenseRow {
        struct ExpenseInput: Content {
            var amount: String
            var category: String
            var note: String?
            var expenseDate: String?
            var isBusinessUse: String?
            var mileage: String?
            var wasMOT: String?
            var photo: File?
        }

        let instructorID = try req.auth.require(User.self).requireID()
        let input = try req.content.decode(ExpenseInput.self)

        guard let amountDecimal = Decimal(string: input.amount), amountDecimal > 0 else {
            throw Abort(.badRequest, reason: "Invalid amount")
        }

        let dateFormatter = ISO8601DateFormatter()
        let expenseDate: Date
        if let ds = input.expenseDate, let d = dateFormatter.date(from: ds) {
            expenseDate = d
        } else {
            expenseDate = Date()
        }

        let isBusinessUse = input.isBusinessUse?.lowercased() != "false"
        let mileage = input.mileage.flatMap { Int($0) }

        let entry = ExpenseEntry(
            instructorID:  instructorID,
            amount:        amountDecimal,
            category:      input.category.lowercased(),
            note:          input.note?.isEmpty == true ? nil : input.note,
            expenseDate:   expenseDate,
            isBusinessUse: isBusinessUse,
            mileage:       mileage
        )
        try await entry.save(on: req.db)

        if let photo = input.photo, photo.data.readableBytes > 0 {
            let expenseID = try entry.requireID()
            let uploadsDir = req.application.directory.workingDirectory + "uploads/receipts"
            try FileManager.default.createDirectory(atPath: uploadsDir, withIntermediateDirectories: true)
            let path = uploadsDir + "/\(expenseID.uuidString).jpg"
            try await req.fileio.writeFile(photo.data, at: path)
            entry.receiptPath = path
            try await entry.save(on: req.db)
        }

        // If this expense was an MOT, create a vehicle log entry recording the MOT dates
        if input.wasMOT?.lowercased() == "true" {
            let cal = Calendar.current
            let motExpiry = cal.date(byAdding: .year, value: 1, to: expenseDate)
            let motLog = VehicleLog(
                instructorID:  instructorID,
                logDate:       expenseDate,
                lastMOTDate:   expenseDate,
                motExpiryDate: motExpiry,
                notes:         "MOT — auto-logged from expense"
            )
            try await motLog.save(on: req.db)
        }

        return try toExpenseRow(entry)
    }

    // ── GET /instructor/vehicle/expenses ─────────────────────────────────────────

    func listExpenses(req: Request) async throws -> [ExpenseRow] {
        let instructorID = try req.auth.require(User.self).requireID()
        let year = req.query[Int.self, at: "year"]

        var query = ExpenseEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$expenseDate, .descending)

        if let y = year {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            var comps = DateComponents(); comps.year = y; comps.month = 1; comps.day = 1
            let start = cal.date(from: comps)!
            comps.year = y + 1
            let end = cal.date(from: comps)!
            query = query.filter(\.$expenseDate >= start).filter(\.$expenseDate < end)
        }

        let entries = try await query.all()
        return try entries.map { try toExpenseRow($0) }
    }

    // ── GET /instructor/vehicle/expenses/summary ─────────────────────────────────

    func expenseSummary(req: Request) async throws -> ExpenseSummaryResponse {
        let instructorID = try req.auth.require(User.self).requireID()
        let year = req.query[Int.self, at: "year"] ?? Calendar.current.component(.year, from: Date())

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents(); comps.year = year; comps.month = 1; comps.day = 1
        let start = cal.date(from: comps)!
        comps.year = year + 1
        let end = cal.date(from: comps)!

        let entries = try await ExpenseEntry.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .filter(\.$expenseDate >= start)
            .filter(\.$expenseDate < end)
            .all()

        var byCategory: [String: Double] = [:]
        var totalBusiness: Double = 0
        var totalPersonal: Double = 0

        for e in entries {
            let amt = (e.amount as NSDecimalNumber).doubleValue
            byCategory[e.category, default: 0] += amt
            if e.isBusinessUse { totalBusiness += amt } else { totalPersonal += amt }
        }

        return ExpenseSummaryResponse(
            year:            year,
            totalByCategory: byCategory,
            totalBusiness:   totalBusiness,
            totalPersonal:   totalPersonal,
            grandTotal:      totalBusiness + totalPersonal,
            expenseCount:    entries.count
        )
    }

    // ── GET /instructor/vehicle/expenses/:expenseID/receipt ──────────────────────

    func getReceipt(req: Request) async throws -> Response {
        let instructorID = try req.auth.require(User.self).requireID()
        guard let expenseID = req.parameters.get("expenseID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid expenseID")
        }
        guard let entry = try await ExpenseEntry.find(expenseID, on: req.db) else {
            throw Abort(.notFound)
        }
        guard entry.$instructor.id == instructorID else { throw Abort(.forbidden) }
        guard let path = entry.receiptPath, FileManager.default.fileExists(atPath: path) else {
            throw Abort(.notFound, reason: "No receipt on file")
        }
        return req.fileio.streamFile(at: path)
    }

    // ── Shared status builder ────────────────────────────────────────────────────

    private func buildStatus(instructorID: UUID, db: Database) async throws -> VehicleStatusResponse {
        let logs = try await VehicleLog.query(on: db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$logDate, .descending)
            .all()

        let latestLog      = logs.first
        let lastServiceLog = logs.first(where: { $0.serviceDate != nil })
        let lastMOTLog     = logs.first(where: { $0.motExpiryDate != nil })

        var nextServiceDate: Date?
        var nextServiceMileage: Int?
        var daysSinceLastService: Int?
        var milesSinceLastService: Int?

        let cal = Calendar.current

        if let svcLog = lastServiceLog, let svcDate = svcLog.serviceDate {
            nextServiceDate = cal.date(byAdding: .year, value: 1, to: svcDate)
            daysSinceLastService = cal.dateComponents([.day], from: svcDate, to: Date()).day
            if let svcOdo = svcLog.odometer {
                nextServiceMileage = svcOdo + 10_000
                if let currentOdo = latestLog?.odometer {
                    milesSinceLastService = currentOdo - svcOdo
                }
            }
        }

        let motExpiryDate = lastMOTLog?.motExpiryDate
        let lastMOTDate   = lastMOTLog?.lastMOTDate
        let currentOdo    = latestLog?.odometer

        let alerts = calculateAlerts(
            motExpiryDate:      motExpiryDate,
            nextServiceDate:    nextServiceDate,
            nextServiceMileage: nextServiceMileage,
            currentOdometer:    currentOdo
        )

        return VehicleStatusResponse(
            latestLog:            try latestLog.map    { try toLogRow($0) },
            lastServiceLog:       try lastServiceLog.map { try toLogRow($0) },
            nextServiceDate:      nextServiceDate,
            nextServiceMileage:   nextServiceMileage,
            daysSinceLastService: daysSinceLastService,
            milesSinceLastService: milesSinceLastService,
            motExpiryDate:        motExpiryDate,
            lastMOTDate:          lastMOTDate,
            alerts:               alerts
        )
    }

    // ── Alert calculation ────────────────────────────────────────────────────────

    private func calculateAlerts(
        motExpiryDate: Date?,
        nextServiceDate: Date?,
        nextServiceMileage: Int?,
        currentOdometer: Int?
    ) -> [VehicleAlert] {
        var alerts: [VehicleAlert] = []
        let today = Date()
        let cal   = Calendar.current

        // MOT alert (urgent ≤30 days, warning 31–60 days)
        if let expiry = motExpiryDate {
            let days = cal.dateComponents([.day], from: today, to: expiry).day ?? 0
            if days <= 0 {
                alerts.append(VehicleAlert(
                    type: "mot", severity: "urgent",
                    message: "MOT expired \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 30 {
                alerts.append(VehicleAlert(
                    type: "mot", severity: "urgent",
                    message: "MOT due in \(days) day\(days == 1 ? "" : "s")",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 60 {
                alerts.append(VehicleAlert(
                    type: "mot", severity: "warning",
                    message: "MOT due in \(days) days",
                    daysUntil: days, milesUntil: nil))
            }
        }

        // Service date alert (urgent ≤30 days, warning 31–60 days)
        if let svcDate = nextServiceDate {
            let days = cal.dateComponents([.day], from: today, to: svcDate).day ?? 0
            if days <= 0 {
                alerts.append(VehicleAlert(
                    type: "service_date", severity: "urgent",
                    message: "Service overdue by \(abs(days)) day\(abs(days) == 1 ? "" : "s")",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 30 {
                alerts.append(VehicleAlert(
                    type: "service_date", severity: "urgent",
                    message: "Service due in \(days) day\(days == 1 ? "" : "s")",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 60 {
                alerts.append(VehicleAlert(
                    type: "service_date", severity: "warning",
                    message: "Service due in \(days) days",
                    daysUntil: days, milesUntil: nil))
            }
        }

        // Service mileage alert (urgent ≤500 miles, warning 501–1000 miles)
        if let nextMiles = nextServiceMileage, let currentOdo = currentOdometer {
            let milesLeft = nextMiles - currentOdo
            if milesLeft <= 0 {
                alerts.append(VehicleAlert(
                    type: "service_mileage", severity: "urgent",
                    message: "Service overdue by \(abs(milesLeft).formatted()) miles",
                    daysUntil: nil, milesUntil: milesLeft))
            } else if milesLeft <= 500 {
                alerts.append(VehicleAlert(
                    type: "service_mileage", severity: "urgent",
                    message: "Service due in \(milesLeft.formatted()) miles",
                    daysUntil: nil, milesUntil: milesLeft))
            } else if milesLeft <= 1000 {
                alerts.append(VehicleAlert(
                    type: "service_mileage", severity: "warning",
                    message: "Service due in \(milesLeft.formatted()) miles",
                    daysUntil: nil, milesUntil: milesLeft))
            }
        }

        return alerts
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    private func toLogRow(_ log: VehicleLog) throws -> VehicleLogRow {
        VehicleLogRow(
            id:                  try log.requireID(),
            logDate:             log.logDate,
            odometer:            log.odometer,
            tyrePressureChecked: log.tyrePressureChecked,
            serviceDate:         log.serviceDate,
            fuelLitres:          log.fuelLitres.map { ($0 as NSDecimalNumber).doubleValue },
            lastMOTDate:         log.lastMOTDate,
            motExpiryDate:       log.motExpiryDate,
            notes:               log.notes,
            createdAt:           log.createdAt
        )
    }

    private func toExpenseRow(_ entry: ExpenseEntry) throws -> ExpenseRow {
        ExpenseRow(
            id:            try entry.requireID(),
            amount:        (entry.amount as NSDecimalNumber).doubleValue,
            category:      entry.category,
            note:          entry.note,
            expenseDate:   entry.expenseDate,
            isBusinessUse: entry.isBusinessUse,
            mileage:       entry.mileage,
            hasReceipt:    entry.receiptPath != nil,
            createdAt:     entry.createdAt
        )
    }
}

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
        let type: String      // "mot" | "service_date" | "service_mileage" | "road_tax" | "insurance"
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
        let vendor: String?
        let note: String?
        let expenseDate: Date
        let isBusinessUse: Bool
        let businessUsePercent: Double
        let claimableAmount: Double
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

    struct ServiceRecordRow: Content {
        let id: UUID
        let serviceDate: Date
        let odometer: Int?
        let serviceType: String
        let cost: Double?
        let whatWasCovered: String?
        let advisories: String?
        let notes: String?
        let createdAt: Date?
    }

    struct MOTRecordRow: Content {
        let id: UUID
        let testDate: Date
        let odometer: Int?
        let cost: Double?
        let result: String
        let expiryDate: Date?
        let advisories: String?
        let essentialRepairs: String?
        let notes: String?
        let createdAt: Date?
    }

    struct VehicleDocumentRow: Content {
        let roadTaxDueDate: Date?
        let roadTaxCost: Double?
        let roadTaxReminderDaysBefore: Int
        let insuranceProvider: String?
        let insurancePolicyNumber: String?
        let insuranceRenewalDate: Date?
        let insuranceAnnualCost: Double?
        let insuranceReminderDaysBefore: Int
    }

    struct InsuranceClaimRow: Content {
        let id: UUID
        let claimDate: Date
        let description: String
        let amountClaimed: Double?
        let excessPaid: Double?
        let excessExpenseEntryID: UUID?
        let status: String
        let notes: String?
        let createdAt: Date?
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
            var vendor: String?
            var note: String?
            var expenseDate: String?
            var isBusinessUse: String?
            var businessUsePercent: String?
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

        let businessUsePercent = input.businessUsePercent.flatMap { Double($0) } ?? 100.0
        let isBusinessUse = businessUsePercent > 0
        let mileage = input.mileage.flatMap { Int($0) }

        let entry = ExpenseEntry(
            instructorID:       instructorID,
            amount:             amountDecimal,
            category:           input.category.lowercased(),
            vendor:             input.vendor?.isEmpty == true ? nil : input.vendor,
            note:               input.note?.isEmpty == true ? nil : input.note,
            expenseDate:        expenseDate,
            isBusinessUse:      isBusinessUse,
            businessUsePercent: businessUsePercent,
            mileage:            mileage
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
            let amt       = (e.amount as NSDecimalNumber).doubleValue
            let claimable = (amt * e.businessUsePercent / 100 * 100).rounded() / 100
            byCategory[e.category, default: 0] += claimable
            if e.isBusinessUse { totalBusiness += claimable } else { totalPersonal += amt }
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

    // ── PATCH /instructor/vehicle/expenses/:expenseID ────────────────────────────

    func updateExpense(req: Request) async throws -> ExpenseRow {
        struct UpdateExpenseInput: Content {
            let amount: Double
            let category: String
            let vendor: String?
            let note: String?
            let expenseDate: Date
            let businessUsePercent: Double
            let mileage: Int?
        }

        let instructorID = try req.auth.require(User.self).requireID()
        guard let expenseID = req.parameters.get("expenseID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid expenseID")
        }
        guard let entry = try await ExpenseEntry.find(expenseID, on: req.db) else {
            throw Abort(.notFound)
        }
        guard entry.$instructor.id == instructorID else { throw Abort(.forbidden) }

        let input = try req.content.decode(UpdateExpenseInput.self)
        guard input.amount > 0 else {
            throw Abort(.badRequest, reason: "Invalid amount")
        }

        entry.amount             = Decimal(input.amount)
        entry.category            = input.category.lowercased()
        entry.vendor              = input.vendor?.isEmpty == true ? nil : input.vendor
        entry.note                = input.note?.isEmpty == true ? nil : input.note
        entry.expenseDate         = input.expenseDate
        entry.businessUsePercent  = input.businessUsePercent
        entry.isBusinessUse       = input.businessUsePercent > 0
        entry.mileage             = input.mileage

        try await entry.save(on: req.db)
        return try toExpenseRow(entry)
    }

    // ── DELETE /instructor/vehicle/expenses/:expenseID ───────────────────────────

    func deleteExpense(req: Request) async throws -> HTTPStatus {
        let instructorID = try req.auth.require(User.self).requireID()
        guard let expenseID = req.parameters.get("expenseID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid expenseID")
        }
        guard let entry = try await ExpenseEntry.find(expenseID, on: req.db) else {
            throw Abort(.notFound)
        }
        guard entry.$instructor.id == instructorID else { throw Abort(.forbidden) }

        if let path = entry.receiptPath, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        try await entry.delete(on: req.db)
        return .noContent
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

    // ── Service records ──────────────────────────────────────────────────────────

    func createServiceRecord(req: Request) async throws -> ServiceRecordRow {
        struct Input: Content {
            let serviceDate: Date?
            let odometer: Int?
            let serviceType: String
            let cost: Double?
            let whatWasCovered: String?
            let advisories: String?
            let notes: String?
        }
        let instructorID = try req.auth.require(User.self).requireID()
        let input = try req.content.decode(Input.self)
        let record = ServiceRecord(
            instructorID:   instructorID,
            serviceDate:    input.serviceDate ?? Date(),
            odometer:       input.odometer,
            serviceType:    input.serviceType,
            cost:           input.cost.map { Decimal($0) },
            whatWasCovered: input.whatWasCovered?.isEmpty == true ? nil : input.whatWasCovered,
            advisories:     input.advisories?.isEmpty == true ? nil : input.advisories,
            notes:          input.notes?.isEmpty == true ? nil : input.notes
        )
        try await record.save(on: req.db)
        return try toServiceRow(record)
    }

    func listServiceRecords(req: Request) async throws -> [ServiceRecordRow] {
        let instructorID = try req.auth.require(User.self).requireID()
        let records = try await ServiceRecord.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$serviceDate, .descending)
            .all()
        return try records.map { try toServiceRow($0) }
    }

    func updateServiceRecord(req: Request) async throws -> ServiceRecordRow {
        struct Input: Content {
            let serviceDate: Date
            let odometer: Int?
            let serviceType: String
            let cost: Double?
            let whatWasCovered: String?
            let advisories: String?
            let notes: String?
        }
        let instructorID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("serviceID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid serviceID")
        }
        guard let record = try await ServiceRecord.find(id, on: req.db) else { throw Abort(.notFound) }
        guard record.$instructor.id == instructorID else { throw Abort(.forbidden) }

        let input = try req.content.decode(Input.self)
        record.serviceDate = input.serviceDate
        record.odometer = input.odometer
        record.serviceType = input.serviceType
        record.cost = input.cost.map { Decimal($0) }
        record.whatWasCovered = input.whatWasCovered?.isEmpty == true ? nil : input.whatWasCovered
        record.advisories = input.advisories?.isEmpty == true ? nil : input.advisories
        record.notes = input.notes?.isEmpty == true ? nil : input.notes
        try await record.save(on: req.db)
        return try toServiceRow(record)
    }

    func deleteServiceRecord(req: Request) async throws -> HTTPStatus {
        let instructorID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("serviceID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid serviceID")
        }
        guard let record = try await ServiceRecord.find(id, on: req.db) else { throw Abort(.notFound) }
        guard record.$instructor.id == instructorID else { throw Abort(.forbidden) }
        try await record.delete(on: req.db)
        return .noContent
    }

    // ── MOT records ───────────────────────────────────────────────────────────────

    func createMOTRecord(req: Request) async throws -> MOTRecordRow {
        struct Input: Content {
            let testDate: Date?
            let odometer: Int?
            let cost: Double?
            let result: String
            let expiryDate: Date?
            let advisories: String?
            let essentialRepairs: String?
            let notes: String?
        }
        let instructorID = try req.auth.require(User.self).requireID()
        let input = try req.content.decode(Input.self)
        let testDate = input.testDate ?? Date()
        let result = input.result.lowercased()
        let expiryDate = input.expiryDate
            ?? (result == "pass" ? Calendar.current.date(byAdding: .year, value: 1, to: testDate) : nil)

        let record = MOTRecord(
            instructorID:     instructorID,
            testDate:         testDate,
            odometer:         input.odometer,
            cost:             input.cost.map { Decimal($0) },
            result:           result,
            expiryDate:       expiryDate,
            advisories:       input.advisories?.isEmpty == true ? nil : input.advisories,
            essentialRepairs: input.essentialRepairs?.isEmpty == true ? nil : input.essentialRepairs,
            notes:            input.notes?.isEmpty == true ? nil : input.notes
        )
        try await record.save(on: req.db)
        return try toMOTRow(record)
    }

    func listMOTRecords(req: Request) async throws -> [MOTRecordRow] {
        let instructorID = try req.auth.require(User.self).requireID()
        let records = try await MOTRecord.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$testDate, .descending)
            .all()
        return try records.map { try toMOTRow($0) }
    }

    func updateMOTRecord(req: Request) async throws -> MOTRecordRow {
        struct Input: Content {
            let testDate: Date
            let odometer: Int?
            let cost: Double?
            let result: String
            let expiryDate: Date?
            let advisories: String?
            let essentialRepairs: String?
            let notes: String?
        }
        let instructorID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("motID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid motID")
        }
        guard let record = try await MOTRecord.find(id, on: req.db) else { throw Abort(.notFound) }
        guard record.$instructor.id == instructorID else { throw Abort(.forbidden) }

        let input = try req.content.decode(Input.self)
        let result = input.result.lowercased()
        record.testDate = input.testDate
        record.odometer = input.odometer
        record.cost = input.cost.map { Decimal($0) }
        record.result = result
        record.expiryDate = input.expiryDate
            ?? (result == "pass" ? Calendar.current.date(byAdding: .year, value: 1, to: input.testDate) : nil)
        record.advisories = input.advisories?.isEmpty == true ? nil : input.advisories
        record.essentialRepairs = input.essentialRepairs?.isEmpty == true ? nil : input.essentialRepairs
        record.notes = input.notes?.isEmpty == true ? nil : input.notes
        try await record.save(on: req.db)
        return try toMOTRow(record)
    }

    func deleteMOTRecord(req: Request) async throws -> HTTPStatus {
        let instructorID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("motID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid motID")
        }
        guard let record = try await MOTRecord.find(id, on: req.db) else { throw Abort(.notFound) }
        guard record.$instructor.id == instructorID else { throw Abort(.forbidden) }
        try await record.delete(on: req.db)
        return .noContent
    }

    // ── Vehicle documents (road tax / insurance — single row per instructor) ───────

    func getVehicleDocument(req: Request) async throws -> VehicleDocumentRow {
        let instructorID = try req.auth.require(User.self).requireID()
        let doc = try await VehicleDocument.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .first()
        return toDocumentRow(doc)
    }

    func updateVehicleDocument(req: Request) async throws -> VehicleDocumentRow {
        struct Input: Content {
            let roadTaxDueDate: Date?
            let roadTaxCost: Double?
            let roadTaxReminderDaysBefore: Int?
            let insuranceProvider: String?
            let insurancePolicyNumber: String?
            let insuranceRenewalDate: Date?
            let insuranceAnnualCost: Double?
            let insuranceReminderDaysBefore: Int?
        }
        let instructorID = try req.auth.require(User.self).requireID()
        let input = try req.content.decode(Input.self)
        let doc = try await findOrCreateDocument(instructorID: instructorID, db: req.db)

        doc.roadTaxDueDate = input.roadTaxDueDate
        doc.roadTaxCost = input.roadTaxCost.map { Decimal($0) }
        doc.roadTaxReminderDaysBefore = input.roadTaxReminderDaysBefore ?? doc.roadTaxReminderDaysBefore
        doc.insuranceProvider = input.insuranceProvider?.isEmpty == true ? nil : input.insuranceProvider
        doc.insurancePolicyNumber = input.insurancePolicyNumber?.isEmpty == true ? nil : input.insurancePolicyNumber
        doc.insuranceRenewalDate = input.insuranceRenewalDate
        doc.insuranceAnnualCost = input.insuranceAnnualCost.map { Decimal($0) }
        doc.insuranceReminderDaysBefore = input.insuranceReminderDaysBefore ?? doc.insuranceReminderDaysBefore
        try await doc.save(on: req.db)
        return toDocumentRow(doc)
    }

    private func findOrCreateDocument(instructorID: UUID, db: Database) async throws -> VehicleDocument {
        if let existing = try await VehicleDocument.query(on: db)
            .filter(\.$instructor.$id == instructorID)
            .first() {
            return existing
        }
        let doc = VehicleDocument(instructorID: instructorID)
        try await doc.save(on: db)
        return doc
    }

    // ── Insurance claims ─────────────────────────────────────────────────────────

    func createInsuranceClaim(req: Request) async throws -> InsuranceClaimRow {
        struct Input: Content {
            let claimDate: Date?
            let description: String
            let amountClaimed: Double?
            let excessPaid: Double?
            let excessExpenseEntryID: UUID?
            let status: String?
            let notes: String?
        }
        let instructorID = try req.auth.require(User.self).requireID()
        let input = try req.content.decode(Input.self)

        let resolvedExcess = try await resolveExcess(
            instructorID: instructorID, manual: input.excessPaid,
            linkedExpenseID: input.excessExpenseEntryID, db: req.db
        )

        let claim = InsuranceClaim(
            instructorID:         instructorID,
            claimDate:            input.claimDate ?? Date(),
            claimDescription:     input.description,
            amountClaimed:        input.amountClaimed.map { Decimal($0) },
            excessPaid:           resolvedExcess,
            excessExpenseEntryID: input.excessExpenseEntryID,
            status:               input.status ?? "open",
            notes:                input.notes?.isEmpty == true ? nil : input.notes
        )
        try await claim.save(on: req.db)
        return try toClaimRow(claim)
    }

    func listInsuranceClaims(req: Request) async throws -> [InsuranceClaimRow] {
        let instructorID = try req.auth.require(User.self).requireID()
        let claims = try await InsuranceClaim.query(on: req.db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$claimDate, .descending)
            .all()
        return try claims.map { try toClaimRow($0) }
    }

    func updateInsuranceClaim(req: Request) async throws -> InsuranceClaimRow {
        struct Input: Content {
            let claimDate: Date
            let description: String
            let amountClaimed: Double?
            let excessPaid: Double?
            let excessExpenseEntryID: UUID?
            let status: String
            let notes: String?
        }
        let instructorID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("claimID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid claimID")
        }
        guard let claim = try await InsuranceClaim.find(id, on: req.db) else { throw Abort(.notFound) }
        guard claim.$instructor.id == instructorID else { throw Abort(.forbidden) }

        let input = try req.content.decode(Input.self)
        let resolvedExcess = try await resolveExcess(
            instructorID: instructorID, manual: input.excessPaid,
            linkedExpenseID: input.excessExpenseEntryID, db: req.db
        )

        claim.claimDate = input.claimDate
        claim.claimDescription = input.description
        claim.amountClaimed = input.amountClaimed.map { Decimal($0) }
        claim.excessPaid = resolvedExcess
        claim.$excessExpenseEntry.id = input.excessExpenseEntryID
        claim.status = input.status
        claim.notes = input.notes?.isEmpty == true ? nil : input.notes
        try await claim.save(on: req.db)
        return try toClaimRow(claim)
    }

    func deleteInsuranceClaim(req: Request) async throws -> HTTPStatus {
        let instructorID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("claimID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid claimID")
        }
        guard let claim = try await InsuranceClaim.find(id, on: req.db) else { throw Abort(.notFound) }
        guard claim.$instructor.id == instructorID else { throw Abort(.forbidden) }
        try await claim.delete(on: req.db)
        return .noContent
    }

    /// When a claim links to a real logged expense, the excess amount is sourced from
    /// that expense rather than re-typed — falls back to the manual figure otherwise.
    private func resolveExcess(
        instructorID: UUID, manual: Double?, linkedExpenseID: UUID?, db: Database
    ) async throws -> Decimal? {
        guard let linkedID = linkedExpenseID else { return manual.map { Decimal($0) } }
        guard let expense = try await ExpenseEntry.find(linkedID, on: db),
              expense.$instructor.id == instructorID else {
            throw Abort(.badRequest, reason: "Linked expense not found")
        }
        return expense.amount
    }

    // ── Shared status builder ────────────────────────────────────────────────────

    private func buildStatus(instructorID: UUID, db: Database) async throws -> VehicleStatusResponse {
        let logs = try await VehicleLog.query(on: db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$logDate, .descending)
            .all()
        let latestLog = logs.first

        let lastService = try await ServiceRecord.query(on: db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$serviceDate, .descending)
            .first()
        let lastMOT = try await MOTRecord.query(on: db)
            .filter(\.$instructor.$id == instructorID)
            .sort(\.$testDate, .descending)
            .first()
        let document = try await VehicleDocument.query(on: db)
            .filter(\.$instructor.$id == instructorID)
            .first()

        var nextServiceDate: Date?
        var nextServiceMileage: Int?
        var daysSinceLastService: Int?
        var milesSinceLastService: Int?

        let cal = Calendar.current

        if let svc = lastService {
            nextServiceDate = cal.date(byAdding: .year, value: 1, to: svc.serviceDate)
            daysSinceLastService = cal.dateComponents([.day], from: svc.serviceDate, to: Date()).day
            if let svcOdo = svc.odometer {
                nextServiceMileage = svcOdo + 10_000
                if let currentOdo = latestLog?.odometer {
                    milesSinceLastService = currentOdo - svcOdo
                }
            }
        }

        let motExpiryDate = lastMOT?.expiryDate
        let lastMOTDate   = lastMOT?.testDate
        let currentOdo    = latestLog?.odometer

        let alerts = calculateAlerts(
            motExpiryDate:          motExpiryDate,
            nextServiceDate:        nextServiceDate,
            nextServiceMileage:     nextServiceMileage,
            currentOdometer:        currentOdo,
            roadTaxDueDate:         document?.roadTaxDueDate,
            insuranceRenewalDate:   document?.insuranceRenewalDate
        )

        return VehicleStatusResponse(
            latestLog:            try latestLog.map { try toLogRow($0) },
            lastServiceLog:       nil,
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
        currentOdometer: Int?,
        roadTaxDueDate: Date? = nil,
        insuranceRenewalDate: Date? = nil
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

        // Road tax alert (urgent ≤30 days or overdue, warning 31–60 days)
        if let dueDate = roadTaxDueDate {
            let days = cal.dateComponents([.day], from: today, to: dueDate).day ?? 0
            if days <= 0 {
                alerts.append(VehicleAlert(
                    type: "road_tax", severity: "urgent",
                    message: "Road tax expired \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 30 {
                alerts.append(VehicleAlert(
                    type: "road_tax", severity: "urgent",
                    message: "Road tax due in \(days) day\(days == 1 ? "" : "s")",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 60 {
                alerts.append(VehicleAlert(
                    type: "road_tax", severity: "warning",
                    message: "Road tax due in \(days) days",
                    daysUntil: days, milesUntil: nil))
            }
        }

        // Insurance renewal alert (urgent ≤30 days or overdue, warning 31–60 days)
        if let renewalDate = insuranceRenewalDate {
            let days = cal.dateComponents([.day], from: today, to: renewalDate).day ?? 0
            if days <= 0 {
                alerts.append(VehicleAlert(
                    type: "insurance", severity: "urgent",
                    message: "Insurance expired \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 30 {
                alerts.append(VehicleAlert(
                    type: "insurance", severity: "urgent",
                    message: "Insurance renewal due in \(days) day\(days == 1 ? "" : "s")",
                    daysUntil: days, milesUntil: nil))
            } else if days <= 60 {
                alerts.append(VehicleAlert(
                    type: "insurance", severity: "warning",
                    message: "Insurance renewal due in \(days) days",
                    daysUntil: days, milesUntil: nil))
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
        let amount = (entry.amount as NSDecimalNumber).doubleValue
        let pct    = entry.businessUsePercent
        return ExpenseRow(
            id:                 try entry.requireID(),
            amount:             amount,
            category:           entry.category,
            vendor:             entry.vendor,
            note:               entry.note,
            expenseDate:        entry.expenseDate,
            isBusinessUse:      entry.isBusinessUse,
            businessUsePercent: pct,
            claimableAmount:    (amount * pct / 100 * 100).rounded() / 100,
            mileage:            entry.mileage,
            hasReceipt:         entry.receiptPath != nil,
            createdAt:          entry.createdAt
        )
    }

    private func toServiceRow(_ record: ServiceRecord) throws -> ServiceRecordRow {
        ServiceRecordRow(
            id:              try record.requireID(),
            serviceDate:     record.serviceDate,
            odometer:        record.odometer,
            serviceType:     record.serviceType,
            cost:            record.cost.map { ($0 as NSDecimalNumber).doubleValue },
            whatWasCovered:  record.whatWasCovered,
            advisories:      record.advisories,
            notes:           record.notes,
            createdAt:       record.createdAt
        )
    }

    private func toMOTRow(_ record: MOTRecord) throws -> MOTRecordRow {
        MOTRecordRow(
            id:                try record.requireID(),
            testDate:          record.testDate,
            odometer:          record.odometer,
            cost:              record.cost.map { ($0 as NSDecimalNumber).doubleValue },
            result:            record.result,
            expiryDate:        record.expiryDate,
            advisories:        record.advisories,
            essentialRepairs:  record.essentialRepairs,
            notes:             record.notes,
            createdAt:         record.createdAt
        )
    }

    private func toDocumentRow(_ doc: VehicleDocument?) -> VehicleDocumentRow {
        VehicleDocumentRow(
            roadTaxDueDate:              doc?.roadTaxDueDate,
            roadTaxCost:                 doc?.roadTaxCost.map { ($0 as NSDecimalNumber).doubleValue },
            roadTaxReminderDaysBefore:   doc?.roadTaxReminderDaysBefore ?? 14,
            insuranceProvider:           doc?.insuranceProvider,
            insurancePolicyNumber:       doc?.insurancePolicyNumber,
            insuranceRenewalDate:        doc?.insuranceRenewalDate,
            insuranceAnnualCost:         doc?.insuranceAnnualCost.map { ($0 as NSDecimalNumber).doubleValue },
            insuranceReminderDaysBefore: doc?.insuranceReminderDaysBefore ?? 14
        )
    }

    private func toClaimRow(_ claim: InsuranceClaim) throws -> InsuranceClaimRow {
        InsuranceClaimRow(
            id:                    try claim.requireID(),
            claimDate:             claim.claimDate,
            description:           claim.claimDescription,
            amountClaimed:         claim.amountClaimed.map { ($0 as NSDecimalNumber).doubleValue },
            excessPaid:            claim.excessPaid.map { ($0 as NSDecimalNumber).doubleValue },
            excessExpenseEntryID:  claim.$excessExpenseEntry.id,
            status:                claim.status,
            notes:                 claim.notes,
            createdAt:             claim.createdAt
        )
    }
}

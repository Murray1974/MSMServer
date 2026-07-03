import Vapor
import Fluent
import Foundation

struct MileageController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - DTOs

    struct CreateRequest: Content {
        let date: Date
        let miles: Double
        let purpose: String
        let fromLocation: String?
        let toLocation: String?
    }

    struct MileageEntryRow: Content {
        let id: UUID
        let date: Date
        let miles: Double
        let purpose: String
        let fromLocation: String?
        let toLocation: String?
        let createdAt: Date?
        let allowance: Double
    }

    struct MileageSummaryResponse: Content {
        let taxYearStart: Date
        let taxYearMiles: Double
        let taxYearAllowance: Double
        let rateIsReduced: Bool  // true when past 10,000-mile threshold
        let entries: [MileageEntryRow]
    }

    // MARK: - Routes

    func list(_ req: Request) async throws -> MileageSummaryResponse {
        let entries = try await MileageEntry.query(on: req.db)
            .sort(\.$date, .descending)
            .all()

        let taxStart = taxYearStart()
        let taxYearEntries = entries.filter { $0.date >= taxStart }

        // Build running allowance in chronological order within the tax year
        let chronological = taxYearEntries.sorted { $0.date < $1.date }
        var runningMiles = 0.0
        var allowanceByID: [UUID: Double] = [:]

        for entry in chronological {
            let before = runningMiles
            runningMiles += entry.miles
            allowanceByID[entry.id!] = hmrcAllowance(for: runningMiles) - hmrcAllowance(for: before)
        }

        let taxYearMiles = runningMiles
        let taxYearAllowance = hmrcAllowance(for: taxYearMiles)

        let rows = entries.map { e in
            MileageEntryRow(
                id: e.id!,
                date: e.date,
                miles: e.miles,
                purpose: e.purpose,
                fromLocation: e.fromLocation,
                toLocation: e.toLocation,
                createdAt: e.createdAt,
                allowance: allowanceByID[e.id!] ?? 0
            )
        }

        return MileageSummaryResponse(
            taxYearStart: taxStart,
            taxYearMiles: taxYearMiles,
            taxYearAllowance: taxYearAllowance,
            rateIsReduced: taxYearMiles > 10_000,
            entries: rows
        )
    }

    func create(_ req: Request) async throws -> MileageEntryRow {
        let body = try req.content.decode(CreateRequest.self)

        let entry = MileageEntry(
            date: body.date,
            miles: body.miles,
            purpose: body.purpose,
            fromLocation: body.fromLocation,
            toLocation: body.toLocation
        )
        try await entry.save(on: req.db)

        // Recalculate allowance for this entry based on running tax-year total
        let taxStart = taxYearStart()
        let priorMiles = try await MileageEntry.query(on: req.db)
            .filter(\.$date >= taxStart)
            .filter(\.$date < entry.date)
            .all()
            .reduce(0.0) { $0 + $1.miles }

        let allowance = hmrcAllowance(for: priorMiles + entry.miles) - hmrcAllowance(for: priorMiles)

        return MileageEntryRow(
            id: entry.id!,
            date: entry.date,
            miles: entry.miles,
            purpose: entry.purpose,
            fromLocation: entry.fromLocation,
            toLocation: entry.toLocation,
            createdAt: entry.createdAt,
            allowance: allowance
        )
    }

    func delete(_ req: Request) async throws -> HTTPStatus {
        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid entry ID")
        }
        guard let entry = try await MileageEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound)
        }
        try await entry.delete(on: req.db)
        return .noContent
    }

    // MARK: - HMRC helpers

    private func taxYearStart() -> Date {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let startYear = (month > 4 || (month == 4 && day >= 6)) ? year : year - 1
        var start = DateComponents()
        start.year = startYear; start.month = 4; start.day = 6
        return cal.date(from: start) ?? now
    }

    // 45p/mile for first 10,000 miles, 25p/mile thereafter
    private func hmrcAllowance(for miles: Double) -> Double {
        miles <= 10_000 ? miles * 0.45 : 10_000 * 0.45 + (miles - 10_000) * 0.25
    }
}

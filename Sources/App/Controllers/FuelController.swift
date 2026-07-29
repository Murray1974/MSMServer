import Vapor
import Fluent
import Foundation

struct FuelController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - DTOs

    struct FuelEntryDTO: Content {
        let id: UUID
        let date: Date
        let vendor: String
        let totalCost: Double
        let pencePerLitre: Double
        let litres: Double
        let odometerReading: Double
        let isFullTank: Bool
        let milesSinceLastFill: Double?
        let mpg: Double?
        let costPerMile: Double?
        let createdAt: Date?
    }

    struct FuelStatsResponse: Content {
        let entries: [FuelEntryDTO]
        let averageMPG: Double?
        let totalSpendThisMonth: Double
        let totalSpendThisYear: Double
        let cheapestVendor: String?
    }

    struct LogFuelRequest: Content {
        let date: Date
        let vendor: String
        let totalCost: Double
        let pencePerLitre: Double
        let litres: Double
        let odometerReading: Double
        let isFullTank: Bool
    }

    // MARK: - GET /instructor/fuel

    func list(_ req: Request) async throws -> FuelStatsResponse {
        let all = try await FuelEntry.query(on: req.db)
            .sort(\.$date, .descending)
            .all()

        let now = Date()
        var londonCal = Calendar(identifier: .gregorian)
        londonCal.timeZone = TimeZone(identifier: "Europe/London")!

        let monthStart = londonCal.date(from: londonCal.dateComponents([.year, .month], from: now))!
        let yearStart  = londonCal.date(from: londonCal.dateComponents([.year], from: now))!

        let monthEntries = all.filter { $0.date >= monthStart }
        let yearEntries  = all.filter { $0.date >= yearStart }

        let validMPGs = all.compactMap { $0.mpg }.filter { $0 > 0 }
        let averageMPG: Double? = validMPGs.isEmpty ? nil : validMPGs.reduce(0, +) / Double(validMPGs.count)

        let totalSpendThisMonth = monthEntries.reduce(0) { $0 + $1.totalCost }
        let totalSpendThisYear  = yearEntries.reduce(0)  { $0 + $1.totalCost }

        // Cheapest vendor by average pence per litre
        var vendorTotals: [String: (total: Double, count: Int)] = [:]
        for entry in all {
            let existing = vendorTotals[entry.vendor] ?? (0, 0)
            vendorTotals[entry.vendor] = (existing.total + entry.pencePerLitre, existing.count + 1)
        }
        let cheapestVendor = vendorTotals
            .mapValues { $0.total / Double($0.count) }
            .min(by: { $0.value < $1.value })?.key

        let rows = all.map { toDTO($0) }

        return FuelStatsResponse(
            entries: rows,
            averageMPG: averageMPG,
            totalSpendThisMonth: totalSpendThisMonth,
            totalSpendThisYear: totalSpendThisYear,
            cheapestVendor: cheapestVendor
        )
    }

    // MARK: - POST /instructor/fuel

    func log(_ req: Request) async throws -> FuelEntryDTO {
        let body = try req.content.decode(LogFuelRequest.self)

        let entry = FuelEntry(
            date: body.date,
            vendor: body.vendor,
            totalCost: body.totalCost,
            pencePerLitre: body.pencePerLitre,
            litres: body.litres,
            odometerReading: body.odometerReading,
            isFullTank: body.isFullTank,
            milesSinceLastFill: nil,
            mpg: nil,
            costPerMile: nil
        )
        try await entry.save(on: req.db)
        try await recalculateAll(on: req.db)

        guard let saved = try await FuelEntry.find(entry.id, on: req.db) else {
            throw Abort(.internalServerError)
        }
        return toDTO(saved)
    }

    // MARK: - PATCH /instructor/fuel/:entryID

    func update(_ req: Request) async throws -> FuelEntryDTO {
        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid entry ID")
        }
        guard let entry = try await FuelEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(LogFuelRequest.self)

        entry.date = body.date
        entry.vendor = body.vendor
        entry.totalCost = body.totalCost
        entry.pencePerLitre = body.pencePerLitre
        entry.litres = body.litres
        entry.odometerReading = body.odometerReading
        entry.isFullTank = body.isFullTank
        try await entry.save(on: req.db)
        try await recalculateAll(on: req.db)

        guard let saved = try await FuelEntry.find(entryID, on: req.db) else {
            throw Abort(.internalServerError)
        }
        return toDTO(saved)
    }

    // MARK: - DELETE /instructor/fuel/:entryID

    func delete(_ req: Request) async throws -> HTTPStatus {
        guard let entryID = req.parameters.get("entryID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid entry ID")
        }
        guard let entry = try await FuelEntry.find(entryID, on: req.db) else {
            throw Abort(.notFound)
        }
        try await entry.delete(on: req.db)
        try await recalculateAll(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    /// Recomputes milesSinceLastFill/mpg/costPerMile for every entry in chronological
    /// (date-ascending) order. Runs after any insert/update/delete so backdated or
    /// out-of-order entries don't leave stale stats on their new neighbors.
    private func recalculateAll(on db: Database) async throws {
        let all = try await FuelEntry.query(on: db)
            .sort(\.$date, .ascending)
            .all()

        var previous: FuelEntry?
        for entry in all {
            var milesSinceLastFill: Double? = nil
            var mpg: Double? = nil
            var costPerMile: Double? = nil

            if let prev = previous {
                let miles = entry.odometerReading - prev.odometerReading
                if miles > 0 {
                    milesSinceLastFill = miles
                    costPerMile = (entry.totalCost * 100) / miles

                    if entry.isFullTank && prev.isFullTank {
                        let litresPerGallon = 4.54609
                        let gallons = entry.litres / litresPerGallon
                        mpg = gallons > 0 ? miles / gallons : nil
                    }
                }
            }

            if entry.milesSinceLastFill != milesSinceLastFill || entry.mpg != mpg || entry.costPerMile != costPerMile {
                entry.milesSinceLastFill = milesSinceLastFill
                entry.mpg = mpg
                entry.costPerMile = costPerMile
                try await entry.save(on: db)
            }

            previous = entry
        }
    }

    private func toDTO(_ e: FuelEntry) -> FuelEntryDTO {
        FuelEntryDTO(
            id: e.id!,
            date: e.date,
            vendor: e.vendor,
            totalCost: e.totalCost,
            pencePerLitre: e.pencePerLitre,
            litres: e.litres,
            odometerReading: e.odometerReading,
            isFullTank: e.isFullTank,
            milesSinceLastFill: e.milesSinceLastFill,
            mpg: e.mpg,
            costPerMile: e.costPerMile,
            createdAt: e.createdAt
        )
    }
}

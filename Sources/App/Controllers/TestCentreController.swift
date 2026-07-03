import Vapor
import Fluent

struct TestCentreController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let protected = routes.grouped(SessionTokenAuthenticator(), User.guardMiddleware())
        let instructor = protected.grouped("instructor", "test-centres")
        instructor.get(use: list)
        instructor.post(use: create)
        instructor.patch(":centreID", use: update)
        instructor.delete(":centreID", use: delete)

        // DVSA lookup — full seeded list for autocomplete
        protected.get("instructor", "dvsa-centres", use: dvsaList)

        // Student read-only endpoint
        protected.get("student", "test-centres", use: list)
    }

    struct TestCentreDTO: Content {
        var id: UUID
        var name: String
        var address: String?
        var knownTimes: [String]
        var isPrimary: Bool
    }

    struct UpsertInput: Content {
        var name: String?
        var address: String?
        var knownTimes: [String]?
        var isPrimary: Bool?
    }

    private func dto(from centre: TestCentre) -> TestCentreDTO {
        TestCentreDTO(
            id: centre.id ?? UUID(),
            name: centre.name,
            address: centre.address,
            knownTimes: decodeTimes(centre.knownTimes),
            isPrimary: centre.isPrimary
        )
    }

    private func decodeTimes(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private func encodeTimes(_ arr: [String]) -> String {
        (try? String(data: JSONEncoder().encode(arr), encoding: .utf8)) ?? "[]"
    }

    // MARK: - GET /instructor/test-centres  (and /student/test-centres)

    func list(_ req: Request) async throws -> [TestCentreDTO] {
        let centres = try await TestCentre.query(on: req.db)
            .sort(\.$isPrimary, .descending)
            .sort(\.$name)
            .all()
        return centres.map { dto(from: $0) }
    }

    // MARK: - POST /instructor/test-centres

    func create(_ req: Request) async throws -> TestCentreDTO {
        let body = try req.content.decode(UpsertInput.self)
        guard let name = body.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "name is required")
        }
        let centre = TestCentre(name: name.trimmingCharacters(in: .whitespaces),
                                address: body.address,
                                knownTimes: body.knownTimes ?? [])
        try await centre.save(on: req.db)
        return dto(from: centre)
    }

    // MARK: - PATCH /instructor/test-centres/:centreID

    func update(_ req: Request) async throws -> TestCentreDTO {
        guard let centreID = req.parameters.get("centreID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing centreID")
        }
        guard let centre = try await TestCentre.find(centreID, on: req.db) else {
            throw Abort(.notFound, reason: "Test centre not found")
        }
        let body = try req.content.decode(UpsertInput.self)
        if let name = body.name { centre.name = name.trimmingCharacters(in: .whitespaces) }
        if let address = body.address { centre.address = address.isEmpty ? nil : address }
        if let times = body.knownTimes { centre.knownTimes = encodeTimes(times) }
        if let isPrimary = body.isPrimary {
            if isPrimary {
                // Atomically clear all others before marking this one
                try await TestCentre.query(on: req.db)
                    .set(\.$isPrimary, to: false)
                    .update()
            }
            centre.isPrimary = isPrimary
        }
        try await centre.save(on: req.db)
        return dto(from: centre)
    }

    // MARK: - DELETE /instructor/test-centres/:centreID

    func delete(_ req: Request) async throws -> HTTPStatus {
        guard let centreID = req.parameters.get("centreID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing centreID")
        }
        guard let centre = try await TestCentre.find(centreID, on: req.db) else {
            return .ok
        }
        try await centre.delete(on: req.db)
        return .ok
    }

    // MARK: - GET /instructor/dvsa-centres

    struct DVSACentreDTO: Content {
        var name: String
        var region: String
    }

    func dvsaList(_ req: Request) async throws -> [DVSACentreDTO] {
        final class Row: Model, Content, @unchecked Sendable {
            static let schema = "dvsa_centres"
            @ID(key: .id) var id: UUID?
            @Field(key: "name")   var name: String
            @Field(key: "region") var region: String
            init() {}
        }
        let rows = try await Row.query(on: req.db).sort(\.$name).all()
        return rows.map { DVSACentreDTO(name: $0.name, region: $0.region) }
    }
}

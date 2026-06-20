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

        // Student read-only endpoint
        protected.get("student", "test-centres", use: list)
    }

    struct TestCentreDTO: Content {
        var id: UUID
        var name: String
        var knownTimes: [String]
    }

    struct UpsertInput: Content {
        var name: String?
        var knownTimes: [String]?
    }

    private func dto(from centre: TestCentre) -> TestCentreDTO {
        TestCentreDTO(
            id: centre.id ?? UUID(),
            name: centre.name,
            knownTimes: decodeTimes(centre.knownTimes)
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
        let centres = try await TestCentre.query(on: req.db).sort(\.$name).all()
        return centres.map { dto(from: $0) }
    }

    // MARK: - POST /instructor/test-centres

    func create(_ req: Request) async throws -> TestCentreDTO {
        let body = try req.content.decode(UpsertInput.self)
        guard let name = body.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "name is required")
        }
        let centre = TestCentre(name: name.trimmingCharacters(in: .whitespaces),
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
        if let times = body.knownTimes { centre.knownTimes = encodeTimes(times) }
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
}

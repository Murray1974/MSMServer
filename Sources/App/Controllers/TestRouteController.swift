import Vapor
import Fluent
import Foundation

struct TestRouteDTO: Content {
    let id: UUID
    let name: String
    let gpxFilename: String?
    let directionsFilename: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(_ route: TestRoute) {
        self.id = route.id!
        self.name = route.name
        self.gpxFilename = route.gpxOriginalFilename
        self.directionsFilename = route.directionsOriginalFilename
        self.createdAt = route.createdAt
        self.updatedAt = route.updatedAt
    }
}

/// CRUD + per-file upload/download for instructor-built test routes (Resources > Mock
/// Test > Test Routes, client side). Each route optionally carries two independently
/// managed files — a GPX track and a "directions" file — handled with the same
/// multipart-upload-to-local-disk pattern as DocumentController's licence/profile photos.
struct TestRouteController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {}

    // MARK: - GET /instructor/test-routes

    func list(_ req: Request) async throws -> [TestRouteDTO] {
        let routes = try await TestRoute.query(on: req.db)
            .sort(\.$name)
            .all()
        return routes.map(TestRouteDTO.init)
    }

    // MARK: - POST /instructor/test-routes

    func create(_ req: Request) async throws -> TestRouteDTO {
        let instructor = try req.auth.require(User.self)
        struct Input: Content { var name: String }
        let input = try req.content.decode(Input.self)
        let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Abort(.badRequest, reason: "Name cannot be empty.") }

        let route = try TestRoute(instructorID: instructor.requireID(), name: trimmed)
        try await route.save(on: req.db)
        return TestRouteDTO(route)
    }

    // MARK: - PATCH /instructor/test-routes/:routeID

    func rename(_ req: Request) async throws -> TestRouteDTO {
        guard let id = req.parameters.get("routeID", as: UUID.self) else { throw Abort(.badRequest) }
        struct Input: Content { var name: String }
        let input = try req.content.decode(Input.self)
        let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Abort(.badRequest, reason: "Name cannot be empty.") }

        guard let route = try await TestRoute.find(id, on: req.db) else { throw Abort(.notFound) }
        route.name = trimmed
        try await route.save(on: req.db)
        return TestRouteDTO(route)
    }

    // MARK: - DELETE /instructor/test-routes/:routeID

    func delete(_ req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("routeID", as: UUID.self) else { throw Abort(.badRequest) }
        guard let route = try await TestRoute.find(id, on: req.db) else { throw Abort(.notFound) }
        deleteFileIfPresent(route.gpxPath, req: req)
        deleteFileIfPresent(route.directionsPath, req: req)
        try await route.delete(on: req.db)
        return .noContent
    }

    // MARK: - File upload/download/remove — one pair of routes each for gpx + directions

    func uploadGPX(_ req: Request) async throws -> TestRouteDTO { try await uploadFile(req, kind: .gpx) }
    func uploadDirections(_ req: Request) async throws -> TestRouteDTO { try await uploadFile(req, kind: .directions) }
    func downloadGPX(_ req: Request) async throws -> Response { try await downloadFile(req, kind: .gpx) }
    func downloadDirections(_ req: Request) async throws -> Response { try await downloadFile(req, kind: .directions) }
    func removeGPX(_ req: Request) async throws -> TestRouteDTO { try await removeFile(req, kind: .gpx) }
    func removeDirections(_ req: Request) async throws -> TestRouteDTO { try await removeFile(req, kind: .directions) }

    private enum FileKind: String {
        case gpx
        case directions

        var subdirectory: String { "uploads/test_routes/\(rawValue)" }
    }

    private func uploadFile(_ req: Request, kind: FileKind) async throws -> TestRouteDTO {
        guard let id = req.parameters.get("routeID", as: UUID.self) else { throw Abort(.badRequest) }
        guard let route = try await TestRoute.find(id, on: req.db) else { throw Abort(.notFound) }

        struct FileInput: Content { var file: File }
        let input = try req.content.decode(FileInput.self)
        guard input.file.data.readableBytes > 0 else { throw Abort(.badRequest, reason: "File is empty.") }

        let ext = (input.file.filename as NSString).pathExtension
        let filename = id.uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let relativePath = "\(kind.subdirectory)/\(filename)"
        let fullPath = req.application.directory.workingDirectory + relativePath
        try await req.fileio.writeFile(input.file.data, at: fullPath)

        switch kind {
        case .gpx:
            deleteFileIfPresent(route.gpxPath, req: req, skip: relativePath)
            route.gpxPath = relativePath
            route.gpxOriginalFilename = input.file.filename
        case .directions:
            deleteFileIfPresent(route.directionsPath, req: req, skip: relativePath)
            route.directionsPath = relativePath
            route.directionsOriginalFilename = input.file.filename
        }
        try await route.save(on: req.db)
        return TestRouteDTO(route)
    }

    private func downloadFile(_ req: Request, kind: FileKind) async throws -> Response {
        guard let id = req.parameters.get("routeID", as: UUID.self) else { throw Abort(.badRequest) }
        guard let route = try await TestRoute.find(id, on: req.db) else { throw Abort(.notFound) }

        let path = kind == .gpx ? route.gpxPath : route.directionsPath
        guard let path else { throw Abort(.notFound, reason: "No \(kind.rawValue) file on this route.") }

        let fullPath = req.application.directory.workingDirectory + path
        // Same existence check as DocumentController's photo streaming — streamFile(at:)
        // throws an unhandled 500 rather than 404 for a missing path.
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw Abort(.notFound, reason: "File is missing on disk.")
        }
        return req.fileio.streamFile(at: fullPath)
    }

    private func removeFile(_ req: Request, kind: FileKind) async throws -> TestRouteDTO {
        guard let id = req.parameters.get("routeID", as: UUID.self) else { throw Abort(.badRequest) }
        guard let route = try await TestRoute.find(id, on: req.db) else { throw Abort(.notFound) }

        switch kind {
        case .gpx:
            deleteFileIfPresent(route.gpxPath, req: req)
            route.gpxPath = nil
            route.gpxOriginalFilename = nil
        case .directions:
            deleteFileIfPresent(route.directionsPath, req: req)
            route.directionsPath = nil
            route.directionsOriginalFilename = nil
        }
        try await route.save(on: req.db)
        return TestRouteDTO(route)
    }

    private func deleteFileIfPresent(_ relativePath: String?, req: Request, skip: String? = nil) {
        guard let relativePath, relativePath != skip else { return }
        let fullPath = req.application.directory.workingDirectory + relativePath
        try? FileManager.default.removeItem(atPath: fullPath)
    }
}

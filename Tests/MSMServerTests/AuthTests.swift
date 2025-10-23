import XCTVapor
@testable import App

final class AuthTests: XCTestCase {

    // MARK: - Test App Setup
    func withTestApp(_ body: (Application) throws -> Void) throws {
        let app = Application(.testing)
        app.logger.logLevel = .warning

        // Ensure clean teardown
        defer { try? app.autoRevert().wait() }
        defer { app.shutdown() }

        try configure(app)
        try app.autoMigrate().wait()

        try body(app)
    }

    // MARK: - Helpers
    private func register(_ app: Application, _ username: String, _ password: String) throws {
        try app.test(.POST, "/auth/register") { req in
            try req.content.encode(["username": username, "password": password])
        } afterResponse: { res in
            XCTAssertEqual(res.status, .created)
        }
    }

    private func login(_ app: Application, _ username: String, _ password: String) throws -> String {
        var token = ""
        try app.test(.POST, "/auth/login") { req in
            try req.content.encode(["username": username, "password": password])
        } afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            struct Output: Content { let value: String }
            let out = try res.content.decode(Output.self)
            token = out.value
        }
        return token
    }

    private func authHeader(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: token)
        return headers
    }

    // MARK: - Tests
    func testRegisterLoginMeLogoutAll() throws {
        try withTestApp { app in
            try register(app, "testerr", "secret123")
            let token = try login(app, "testerr", "secret123")

            // /auth/me works while authenticated
            try app.test(.GET, "/auth/me", headers: authHeader(token)) { res in
                XCTAssertEqual(res.status, .ok)
            }

            // change password while authenticated
            try app.test(.POST, "/auth/password/change",
                         headers: authHeader(token),
                         beforeRequest: { req in
                             try req.content.encode([
                                 "currentPassword": "secret123",
                                 "newPassword": "newpw"
                             ])
                         }) { res in
                XCTAssertEqual(res.status, .noContent)
            }

            // logout-all
            try app.test(.POST, "/auth/logout-all", headers: authHeader(token)) { res in
                XCTAssertEqual(res.status, .noContent)
            }
        }
    }
}

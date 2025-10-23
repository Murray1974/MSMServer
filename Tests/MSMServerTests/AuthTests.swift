import XCTest
import XCTVapor
@testable import App

final class AuthTests: XCTestCase {

  /// Spin up a fresh app (migrates DB) per test and always tear down.
  private func withTestApp(_ body: (Application) throws -> Void) throws {
    let app = Application(.testing)
    defer { app.shutdown() }

    // Use your production configure() so the wiring matches the real app
    try configure(app)

    // Run migrations against your local Docker Postgres (already running)
    try app.autoMigrate().wait()
    defer { try? app.autoRevert().wait() } // best-effort cleanup

    try body(app)
  }

  // MARK: - Helpers

  private func register(_ app: Application, _ username: String, _ password: String) throws {
    try app.test(.POST, "/auth/register",
      beforeRequest: { req in
        try req.content.encode(["username": username, "password": password])
      },
      afterResponse: { res in
        XCTAssertEqual(res.status, .created)
      })
  }

  private func login(_ app: Application, _ username: String, _ password: String) throws -> String {
    var token = ""
    try app.test(.POST, "/auth/login",
      beforeRequest: { req in
        try req.content.encode(["username": username, "password": password])
      },
      afterResponse: { res in
        XCTAssertEqual(res.status, .ok)
        struct Output: Content { let value: String }
        let out = try res.content.decode(Output.self)
        token = out.value
      })
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
      try register(app, "tester", "secret123")
      let token = try login(app, "tester", "secret123")

      // /auth/me works while authenticated
      try app.test(.GET, "/auth/me",
                   headers: authHeader(token)) { res in
        XCTAssertEqual(res.status, .ok)
      }

      // logout-all revokes all tokens
      try app.test(.POST, "/auth/logout-all",
                   headers: authHeader(token)) { res in
        XCTAssertEqual(res.status, .noContent)
      }

      // token should now be invalid
      try app.test(.GET, "/auth/me",
                   headers: authHeader(token)) { res in
        XCTAssertEqual(res.status, .unauthorized)
      }
    }
  }

  func testPasswordChangeRevokesTokens() throws {
    try withTestApp { app in
      try register(app, "alice", "startpw")
      let t1 = try login(app, "alice", "startpw")

      // Change password
      try app.test(.POST, "/auth/password/change",
                   headers: authHeader(t1),
                   beforeRequest: { req in
                     try req.content.encode([
                       "currentPassword": "startpw",
                       "newPassword": "newpw"
                     ])
                   }) { res in
        XCTAssertEqual(res.status, .noContent)
      }

      // old token no longer works
      try app.test(.GET, "/auth/me",
                   headers: authHeader(t1)) { res in
        XCTAssertEqual(res.status, .unauthorized)
      }

      // new login with new password works
      _ = try login(app, "alice", "newpw")
    }
  }

  func testRateLimitOnLogin() throws {
    // If you want to assert 429s deterministically, either:
    // 1) set env vars before configure() (requires refactor),
    // or 2) just hit real limiter values you wired.
    try withTestApp { app in
      try register(app, "ratetest", "pw")
      for i in 1...4 {
        try app.test(.POST, "/auth/login",
                     beforeRequest: { req in
                       try req.content.encode(["username":"ratetest", "password":"pw"])
                     }) { res in
          if i < 4 { XCTAssertEqual(res.status, .ok) }
          else     { XCTAssertEqual(res.status, .tooManyRequests) }
        }
      }
    }
  }
}

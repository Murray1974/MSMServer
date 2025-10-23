import XCTVapor
@testable import App

final class AppTests: XCTestCase {

    var app: Application!

    override func setUpWithError() throws {
        app = Application(.testing)
        try configure(app)
    }

    override func tearDownWithError() throws {
        app.shutdown()
    }

    // MARK: - Root route

    func testRootRouteReturnsRunning() throws {
        try app.test(.GET, "/", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("MSM Server is running"))
        })
    }

    // MARK: - Health check

    func testHealthRouteReturnsOK() throws {
        try app.test(.GET, "/health", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("ok"))
        })
    }

    // MARK: - Database check

    func testDBCheckRouteReturnsDBOK() throws {
        try app.test(.GET, "/dbcheck", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("db: skipped"))
        })
    }
}

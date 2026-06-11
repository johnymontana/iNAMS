import XCTest
@testable import iNAMSKit

final class NAMSConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "inams-config-tests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testProductionFallbackWithNoOverrides() {
        let config = NAMSConfig.resolved(defaults: defaults, environment: [:])
        XCTAssertEqual(config, .production)
    }

    func testDefaultsOverrideApplies() {
        defaults.set("http://localhost:8080", forKey: "NAMSAPIBaseURL")
        let config = NAMSConfig.resolved(defaults: defaults, environment: [:])
        XCTAssertEqual(config.apiBase.absoluteString, "http://localhost:8080")
        XCTAssertEqual(config.authBase, NAMSConfig.production.authBase, "unset keys keep production values")
    }

    func testEnvironmentBeatsDefaults() {
        defaults.set("http://defaults:1", forKey: "NAMSAPIBaseURL")
        let config = NAMSConfig.resolved(defaults: defaults, environment: [
            "NAMS_API_BASE_URL": "http://env:2",
            "NAMS_AUTH_BASE_URL": "http://env:3",
        ])
        XCTAssertEqual(config.apiBase.absoluteString, "http://env:2")
        XCTAssertEqual(config.authBase.absoluteString, "http://env:3")
    }
}

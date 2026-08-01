import XCTest
@testable import Skwad

final class AppRuntimeTests: XCTestCase {
    func testDetectsXCTestConfigurationEnvironment() {
        XCTAssertTrue(AppRuntime.isRunningTests(environment: [
            "XCTestConfigurationFilePath": "/tmp/SkwadTests.xctestconfiguration"
        ]))
    }

    func testDetectsExplicitTestHostEnvironment() {
        XCTAssertTrue(AppRuntime.isRunningTests(environment: ["SKWAD_TESTING": "1"]))
    }

    func testDoesNotTreatOrdinaryLaunchAsTests() {
        XCTAssertFalse(AppRuntime.isRunningTests(environment: [:]))
    }

    func testCurrentTestProcessIsDetected() {
        XCTAssertTrue(AppRuntime.isRunningTests)
    }

    func testDetectsEmbeddedXCTestBundle() {
        XCTAssertTrue(AppRuntime.hasTestBundle(pluginNames: ["SkwadTests.xctest"]))
        XCTAssertFalse(AppRuntime.hasTestBundle(pluginNames: ["ShareExtension.appex"]))
    }
}

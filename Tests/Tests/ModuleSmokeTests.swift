import XCTest
@testable import DDPAIDashcam

/// Smoke test confirming the DDPAIDashcam module and the unit-test target are
/// wired together. Replaced by real example/unit tests in later tasks.
final class ModuleSmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(DDPAIDashcam.moduleName, "DDPAIDashcam")
    }
}

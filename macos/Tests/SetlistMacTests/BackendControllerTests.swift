import Foundation
import XCTest
@testable import SetlistMac

@MainActor
final class BackendControllerTests: XCTestCase {
    func testAttachesWithoutLaunchingWhenBackendIsAlreadyHealthy() async {
        let configuration = BackendConfiguration(
            projectRoot: FileManager.default.temporaryDirectory
        )
        var didLaunch = false
        let controller = BackendController(
            configuration: configuration,
            healthCheck: { _ in true },
            launcher: { _ in
                didLaunch = true
                return Process()
            },
            retryDelayNanoseconds: 0
        )

        await controller.start()

        XCTAssertEqual(controller.status, .ready)
        XCTAssertFalse(controller.ownsBackend)
        XCTAssertFalse(didLaunch)
    }

    func testLaunchesBackendAndWaitsUntilHealthy() async {
        let configuration = BackendConfiguration(
            projectRoot: FileManager.default.temporaryDirectory
        )
        var healthChecks = 0
        var didLaunch = false
        let controller = BackendController(
            configuration: configuration,
            healthCheck: { _ in
                healthChecks += 1
                return healthChecks > 1
            },
            launcher: { _ in
                didLaunch = true
                return Process()
            },
            retryDelayNanoseconds: 0
        )

        await controller.start()

        XCTAssertEqual(controller.status, .ready)
        XCTAssertTrue(controller.ownsBackend)
        XCTAssertTrue(didLaunch)
    }

    func testReportsFailureWhenOwnedBackendTerminates() async {
        let configuration = BackendConfiguration(
            projectRoot: FileManager.default.temporaryDirectory
        )
        var healthChecks = 0
        let controller = BackendController(
            configuration: configuration,
            healthCheck: { _ in
                healthChecks += 1
                return healthChecks == 2
            },
            launcher: { _ in Process() },
            retryDelayNanoseconds: 0,
            retryAttempts: 1
        )

        await controller.start()

        await controller.handleBackendTermination()

        XCTAssertEqual(
            controller.status,
            .failed("The local server exited unexpectedly.")
        )
        XCTAssertFalse(controller.ownsBackend)
    }
}

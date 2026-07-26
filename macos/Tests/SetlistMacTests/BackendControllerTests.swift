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
            healthCheck: { _ in .setlistOK },
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
                return healthChecks > 1 ? .setlistOK : nil
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

    func testRejectsUnrelatedHealthyServer() async {
        let configuration = BackendConfiguration(
            projectRoot: FileManager.default.temporaryDirectory
        )
        var didLaunch = false
        let controller = BackendController(
            configuration: configuration,
            healthCheck: { _ in
                BackendHealth(status: "ok", app: "SomethingElse")
            },
            launcher: { _ in
                didLaunch = true
                return Process()
            },
            retryDelayNanoseconds: 0,
            retryAttempts: 1
        )

        await controller.start()

        XCTAssertTrue(
            didLaunch,
            "An unrelated healthy server must not be adopted as the engine"
        )
        XCTAssertNotEqual(controller.status, .ready)
    }

    func testRejectsUnhealthyStatusFromSetlistEngine() async {
        let configuration = BackendConfiguration(
            projectRoot: FileManager.default.temporaryDirectory
        )
        var didLaunch = false
        let controller = BackendController(
            configuration: configuration,
            healthCheck: { _ in
                BackendHealth(status: "degraded", app: "Setlist")
            },
            launcher: { _ in
                didLaunch = true
                return Process()
            },
            retryDelayNanoseconds: 0,
            retryAttempts: 1
        )

        await controller.start()

        XCTAssertTrue(didLaunch)
        XCTAssertNotEqual(controller.status, .ready)
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
                return healthChecks == 2 ? .setlistOK : nil
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

    func testHealthResponseDecodesBackendPayload() throws {
        let payload = Data(#"{"status": "ok", "app": "Setlist"}"#.utf8)

        let health = try JSONDecoder().decode(BackendHealth.self, from: payload)

        XCTAssertTrue(health.isCompatibleSetlistEngine)
    }
}

private extension BackendHealth {
    static let setlistOK = BackendHealth(status: "ok", app: "Setlist")
}

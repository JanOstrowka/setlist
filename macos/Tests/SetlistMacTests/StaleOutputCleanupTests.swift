import Foundation
import XCTest
@testable import SetlistMac

final class StaleOutputCleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private func makeCleanup() -> (StaleOutputCleanup, () -> [String]) {
        let log = TrashedPaths()
        let cleanup = StaleOutputCleanup(trash: { url in
            log.append(url.path)
            try FileManager.default.removeItem(at: url)
        })
        return (cleanup, { log.all() })
    }

    func testRenamedTrackInTheSameFolderOnlyTrashesTheOldFile() throws {
        let a = try touch("Set/01 - A.m4a")
        let b = try touch("Set/02 - B.m4a")
        _ = try touch("Set/cover.jpg")
        let c = try touch("Set/02 - C.m4a")
        let (cleanup, trashed) = makeCleanup()

        cleanup.removeStale(previous: [a, b], current: [a, c])

        XCTAssertEqual(trashed(), [b])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Set").path))
    }

    func testOldFolderGoesOnceOnlyCoverArtAndFinderJunkRemain() throws {
        let a = try touch("Old/01 - A.m4a")
        _ = try touch("Old/cover.jpg")
        _ = try touch("Old/.DS_Store")
        let fresh = try touch("New/01 - A.m4a")
        let (cleanup, trashed) = makeCleanup()

        cleanup.removeStale(previous: [a], current: [fresh])

        XCTAssertEqual(trashed(), [a, root.appendingPathComponent("Old").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
    }

    func testOldFolderStaysWhenItHoldsAnythingElse() throws {
        let a = try touch("Old/01 - A.m4a")
        _ = try touch("Old/notes.txt")
        let fresh = try touch("New/01 - A.m4a")
        let (cleanup, trashed) = makeCleanup()

        cleanup.removeStale(previous: [a], current: [fresh])

        XCTAssertEqual(trashed(), [a])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Old").path))
    }

    func testMissingFilesAndSharedFoldersAreSkipped() throws {
        let gone = root.appendingPathComponent("Set/00 - Gone.m4a").path
        let a = try touch("Set/01 - A.m4a")
        let (cleanup, trashed) = makeCleanup()

        cleanup.removeStale(previous: [gone, a], current: [a])

        XCTAssertEqual(trashed(), [])
    }

    func testNothingHappensWithoutPreviousOutputs() throws {
        let a = try touch("Set/01 - A.m4a")
        let (cleanup, trashed) = makeCleanup()

        cleanup.removeStale(previous: [], current: [a])

        XCTAssertEqual(trashed(), [])
    }

    func testNothingHappensWhenTheCurrentOutputsAreNotKnownYet() throws {
        // An empty current list is "not reported yet", never "nothing".
        let a = try touch("Set/01 - A.m4a")
        let (cleanup, trashed) = makeCleanup()

        cleanup.removeStale(previous: [a], current: [])

        XCTAssertEqual(trashed(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }
}

private final class TrashedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.withLock { paths.append(path) }
    }

    func all() -> [String] {
        lock.withLock { paths }
    }
}

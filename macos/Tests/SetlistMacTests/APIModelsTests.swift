import Foundation
import XCTest
@testable import SetlistMac

final class APIModelsTests: XCTestCase {
    func testLegacyProgressPayloadDecodes() throws {
        let data = #"{"stage":"download","pct":25,"message":"Downloading"}"#.data(using: .utf8)!

        let event = try APIJSON.decoder.decode(APIProgressEvent.self, from: data)

        XCTAssertEqual(event.stage, .download)
        XCTAssertEqual(event.stagePercent, 25)
        XCTAssertNil(event.overallPercent)
        XCTAssertNil(event.trackIndex)
    }

    func testRichProgressPayloadDecodes() throws {
        let data = #"{"stage":"split","pct":50,"stage_pct":50,"overall_pct":80,"message":"Cutting","track_index":2,"track_count":4,"track_title":"Second","track_state":"cutting","downloaded_bytes":250,"total_bytes":1000,"speed_bytes_per_second":12.5,"eta_seconds":9,"file_path":"/tmp/track.m4a"}"#.data(using: .utf8)!

        let event = try APIJSON.decoder.decode(APIProgressEvent.self, from: data)

        XCTAssertEqual(event.stagePercent, 50)
        XCTAssertEqual(event.overallPercent, 80)
        XCTAssertEqual(event.trackState, .cutting)
        XCTAssertEqual(event.downloadedBytes, 250)
        XCTAssertEqual(event.filePath, "/tmp/track.m4a")
    }

    func testAllAPIValueTypesAreCodableEquatableAndSendable() throws {
        let metadata = APIMetadataFields(
            title: "Set",
            artist: "DJ",
            album: "Live",
            albumArtist: "DJ",
            year: 2026,
            genre: "Electronic",
            comment: "https://example.test/watch",
            compilation: false
        )
        let track = APITrack(start: 0, title: "Intro", artist: "DJ", end: 60)
        let tracklist = APITracklist(
            source: .chapters,
            tracks: [track],
            album: "Live",
            albumArtist: "DJ",
            note: "Detected"
        )
        let resolve = APIResolveResponse(
            videoID: "video-1",
            duration: 60,
            metadata: metadata,
            cover: "data:image/jpeg;base64,abc",
            formats: "m4a",
            detectedLine: "Detected",
            hasChapters: true,
            tracklist: tracklist
        )
        let download = APIDownloadRequest(
            videoID: "video-1",
            url: "https://example.test/watch",
            metadata: metadata,
            format: .alac,
            cover: "keep",
            callbackURL: ""
        )
        let split = APISplitDownloadRequest(
            videoID: "video-1",
            url: "https://example.test/watch",
            metadata: metadata,
            tracks: [track],
            format: .aac256,
            cover: "keep",
            callbackURL: ""
        )
        let progress = APIProgressEvent(
            stage: .done,
            pct: 100,
            stagePct: 100,
            overallPct: 100,
            message: "Done",
            filePath: "/tmp/track.m4a"
        )
        let snapshot = APIJobSnapshot(
            jobID: "job-1",
            status: .completed,
            latest: progress,
            outputPaths: ["/tmp/track.m4a"],
            error: ""
        )

        assertCodableEquatableSendable(metadata)
        assertCodableEquatableSendable(track)
        assertCodableEquatableSendable(tracklist)
        assertCodableEquatableSendable(resolve)
        assertCodableEquatableSendable(download)
        assertCodableEquatableSendable(split)
        assertCodableEquatableSendable(progress)
        assertCodableEquatableSendable(snapshot)

        let encoded = try APIJSON.encoder.encode(resolve)
        XCTAssertEqual(try APIJSON.decoder.decode(APIResolveResponse.self, from: encoded), resolve)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""video_id":"video-1""#))
    }

    private func assertCodableEquatableSendable<T: Codable & Equatable & Sendable>(
        _ value: T
    ) {
        XCTAssertEqual(value, value)
    }
}

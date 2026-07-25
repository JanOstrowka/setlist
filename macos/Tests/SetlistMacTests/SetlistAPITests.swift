import Foundation
import XCTest
@testable import SetlistMac

@MainActor
final class SetlistAPITests: XCTestCase {
    func testTypedEndpointsUseExpectedMethodsPathsAndBodies() async throws {
        let api = makeAPI()
        let metadata = APIMetadataFields(title: "Set")
        let track = APITrack(start: 0, title: "Intro")

        let resolved = try await api.resolve(url: "https://youtube.test/watch")
        let automatic = try await api.autoTracklist(
            query: "DJ Set",
            url: "https://youtube.test/watch",
            duration: 3600
        )
        let parsed = try await api.parseTracklist(text: "0:00 Intro", duration: 60)
        let jobID = try await api.submit(
            APIDownloadRequest(
                videoID: "video-1",
                url: "https://youtube.test/watch",
                metadata: metadata
            )
        )
        let splitJobID = try await api.submitSplit(
            APISplitDownloadRequest(
                videoID: "video-1",
                url: "https://youtube.test/watch",
                metadata: metadata,
                tracks: [track]
            )
        )
        let snapshot = try await api.job(jobID: "job-1")
        let cancelled = try await api.cancel(jobID: "job-1")

        XCTAssertEqual(resolved.videoID, "video-1")
        XCTAssertEqual(automatic.source, .oneThousandOneTracklists)
        XCTAssertEqual(parsed.source, .manual)
        XCTAssertEqual(jobID, "single-job")
        XCTAssertEqual(splitJobID, "split-job")
        XCTAssertEqual(snapshot.status, .processing)
        XCTAssertEqual(cancelled.status, .cancelling)
    }

    func testNonSuccessStatusThrowsTypedError() async {
        let api = makeAPI()

        do {
            _ = try await api.job(jobID: "missing")
            XCTFail("Expected the request to fail")
        } catch let error as SetlistAPIError {
            XCTAssertEqual(error, .httpStatus(404, Data(#"{"detail":"Unknown job"}"#.utf8)))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProgressDecodesSSEEvents() async throws {
        let events = try await Array(makeAPI().progress(jobID: "stream"))

        XCTAssertEqual(events.map(\.stage), [.download, .done])
        XCTAssertEqual(events.first?.message, "Downloading")
    }

    func testProgressValidatesHTTPStatus() async {
        do {
            _ = try await Array(makeAPI().progress(jobID: "missing"))
            XCTFail("Expected the stream to fail")
        } catch let error as SetlistAPIError {
            XCTAssertEqual(error, .httpStatus(404, Data()))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTerminatingProgressStreamCancelsURLSessionWork() async throws {
        let api = makeAPI()
        let stream = api.progress(jobID: "cancel-me")
        let consumer = Task {
            for try await _ in stream {}
        }

        try await waitUntil { await clientStreamProbe.didStart }
        consumer.cancel()
        _ = try? await consumer.value

        try await waitUntil { await clientStreamProbe.didCancel }
    }

    private func makeAPI() -> SetlistAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientURLProtocol.self]
        return SetlistAPI(
            baseURL: URL(string: "https://setlist.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for URL session state")
    }
}

private actor StreamProbe {
    private(set) var didStart = false
    private(set) var didCancel = false

    func started() {
        didStart = true
    }

    func cancelled() {
        didCancel = true
    }
}

private let clientStreamProbe = StreamProbe()

private final class ClientURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "setlist.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            return
        }

        switch (request.httpMethod ?? "GET", url.path) {
        case ("POST", "/resolve"):
            respond(
                validating: ["url": "https://youtube.test/watch"],
                json: Self.resolveResponse
            )
        case ("POST", "/auto-tracklist"):
            respond(
                validating: [
                    "query": "DJ Set",
                    "url": "https://youtube.test/watch",
                    "duration": 3600,
                ],
                json: Self.tracklist(source: "1001tracklists")
            )
        case ("POST", "/parse-tracklist"):
            respond(
                validating: ["text": "0:00 Intro", "duration": 60],
                json: Self.tracklist(source: "manual")
            )
        case ("POST", "/download"):
            respond(
                requiringBodyValues: [
                    "video_id": "video-1",
                    "callback_url": "",
                ],
                json: #"{"job_id":"single-job"}"#
            )
        case ("POST", "/download-split"):
            respond(
                requiringBodyValues: [
                    "video_id": "video-1",
                    "callback_url": "",
                ],
                json: #"{"job_id":"split-job"}"#
            )
        case ("GET", "/jobs/job-1"):
            respond(json: Self.snapshot(status: "processing"))
        case ("POST", "/jobs/job-1/cancel"):
            respond(json: Self.snapshot(status: "cancelling"))
        case ("GET", "/jobs/missing"):
            respond(status: 404, json: #"{"detail":"Unknown job"}"#)
        case ("GET", "/progress/stream"):
            respond(
                contentType: "text/event-stream",
                chunks: [
                    Data(": heartbeat\r\n\r\n".utf8),
                    Data("data: {\"stage\":\"download\",\"pct\":25,\"message\":\"Down".utf8),
                    Data("loading\"}\r\n\r\ndata: {\"stage\":\"done\",\"pct\":100,\"message\":\"Done\"}\n\n".utf8),
                ]
            )
        case ("GET", "/progress/missing"):
            respond(
                status: 404,
                contentType: "text/event-stream",
                chunks: [Data(#"{"detail":"Unknown job"}"#.utf8)]
            )
        case ("GET", "/progress/cancel-me"):
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let probe = clientStreamProbe
            Task.detached {
                await probe.started()
            }
        default:
            respond(status: 500, json: #"{"detail":"Unexpected request"}"#)
        }
    }

    override func stopLoading() {
        guard request.url?.path == "/progress/cancel-me" else {
            return
        }
        let probe = clientStreamProbe
        Task.detached {
            await probe.cancelled()
        }
    }

    private func respond(
        validating expectedBody: [String: Any],
        json: String
    ) {
        guard let actualBody = requestBody(),
              NSDictionary(dictionary: actualBody).isEqual(to: expectedBody) else {
            respond(status: 422, json: #"{"detail":"Invalid request body"}"#)
            return
        }
        respond(json: json)
    }

    private func respond(
        requiringBodyValues expectedValues: [String: Any],
        json: String
    ) {
        guard let body = requestBody(),
              expectedValues.allSatisfy({
                  (body[$0.key] as? NSObject) == ($0.value as? NSObject)
              }) else {
            respond(status: 422, json: #"{"detail":"Invalid request body"}"#)
            return
        }
        respond(json: json)
    }

    private func requestBody() -> [String: Any]? {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(status: Int = 200, json: String) {
        respond(
            status: status,
            contentType: "application/json",
            chunks: [Data(json.utf8)]
        )
    }

    private func respond(
        status: Int = 200,
        contentType: String,
        chunks: [Data]
    ) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static let resolveResponse = """
        {
          "video_id": "video-1",
          "duration": 3600,
          "metadata": {
            "title": "Set",
            "artist": "DJ",
            "album": "",
            "album_artist": "",
            "year": null,
            "genre": "",
            "comment": "",
            "compilation": false
          },
          "cover": "",
          "formats": "m4a",
          "detected_line": "Detected",
          "has_chapters": false,
          "tracklist": null
        }
        """

    private static func tracklist(source: String) -> String {
        """
        {
          "source": "\(source)",
          "tracks": [],
          "album": "",
          "album_artist": "",
          "note": ""
        }
        """
    }

    private static func snapshot(status: String) -> String {
        """
        {
          "job_id": "job-1",
          "status": "\(status)",
          "latest": {
            "stage": "queued",
            "pct": 0,
            "message": ""
          },
          "output_paths": [],
          "error": ""
        }
        """
    }
}

private extension Array {
    init<S: AsyncSequence>(_ sequence: S) async throws where S.Element == Element {
        self = []
        for try await element in sequence {
            append(element)
        }
    }
}

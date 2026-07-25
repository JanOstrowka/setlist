import Foundation
import XCTest
@testable import SetlistMac

final class SSEDecoderTests: XCTestCase {
    func testDecodesTwoEventsAcrossArbitraryByteChunks() {
        let stream = Data(
            "data: {\"stage\":\"download\",\"message\":\"Música\"}\n\n"
                .utf8
        ) + Data("data:{\"stage\":\"done\"}\n\n".utf8)
        var decoder = SSEDecoder()
        var payloads: [Data] = []

        for byte in stream {
            payloads += decoder.append(Data([byte]))
        }

        XCTAssertEqual(
            payloads.map { String(decoding: $0, as: UTF8.self) },
            [
                #"{"stage":"download","message":"Música"}"#,
                #"{"stage":"done"}"#,
            ]
        )
    }

    func testHandlesCRLFCommentsHeartbeatsAndMultipleDataLines() {
        var decoder = SSEDecoder()

        let payloads = decoder.append(
            Data(
                ": heartbeat\r\n\r\n"
                    .appending("event: progress\r\n")
                    .appending("data: first\r\n")
                    .appending("data: second\r\n\r\n")
                    .appending("retry: 1000\n\n")
                    .utf8
            )
        )

        XCTAssertEqual(payloads, [Data("first\nsecond".utf8)])
    }

    func testRetainsIncompleteTailWithoutDroppingBytes() {
        var decoder = SSEDecoder()

        XCTAssertEqual(
            decoder.append(Data("data: {\"message\":\"partial".utf8)),
            []
        )
        XCTAssertEqual(decoder.append(Data(" value\"}\r".utf8)), [])
        XCTAssertEqual(
            decoder.append(Data("\n\r\n".utf8)),
            [Data(#"{"message":"partial value"}"#.utf8)]
        )
    }
}

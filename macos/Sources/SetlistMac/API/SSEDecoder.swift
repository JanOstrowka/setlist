import Foundation

struct SSEDecoder: Sendable {
    private var buffer: [UInt8] = []

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var payloads: [Data] = []

        while let boundary = nextEventBoundary() {
            let event = buffer[..<boundary.eventEnd]
            if let payload = Self.payload(from: event) {
                payloads.append(payload)
            }
            buffer.removeFirst(boundary.consumedEnd)
        }

        return payloads
    }

    private func nextEventBoundary() -> (
        eventEnd: Int,
        consumedEnd: Int
    )? {
        var lineStart = 0

        for index in buffer.indices where buffer[index] == Self.lineFeed {
            var contentEnd = index
            if contentEnd > lineStart,
               buffer[contentEnd - 1] == Self.carriageReturn {
                contentEnd -= 1
            }

            if contentEnd == lineStart {
                return (eventEnd: lineStart, consumedEnd: index + 1)
            }
            lineStart = index + 1
        }

        return nil
    }

    private static func payload(
        from event: ArraySlice<UInt8>
    ) -> Data? {
        var dataLines: [[UInt8]] = []

        for rawLine in event.split(
            separator: lineFeed,
            omittingEmptySubsequences: false
        ) {
            var line = rawLine
            if line.last == carriageReturn {
                line = line.dropLast()
            }
            guard !line.isEmpty, line.first != commentMarker else {
                continue
            }

            let colon = line.firstIndex(of: fieldSeparator)
            let field = colon.map { line[..<$0] } ?? line[...]
            guard field.elementsEqual(dataField) else {
                continue
            }

            var value: ArraySlice<UInt8>
            if let colon {
                value = line[line.index(after: colon)...]
                if value.first == space {
                    value = value.dropFirst()
                }
            } else {
                value = []
            }
            dataLines.append(Array(value))
        }

        guard !dataLines.isEmpty else {
            return nil
        }

        var payload: [UInt8] = []
        for (index, line) in dataLines.enumerated() {
            if index > 0 {
                payload.append(lineFeed)
            }
            payload.append(contentsOf: line)
        }
        return Data(payload)
    }

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let commentMarker: UInt8 = 0x3A
    private static let fieldSeparator: UInt8 = 0x3A
    private static let space: UInt8 = 0x20
    private static let dataField = Array("data".utf8)
}

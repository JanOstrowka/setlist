import Foundation

protocol SetlistAPIProtocol: Sendable {
    func resolve(url: String) async throws -> APIResolveResponse
    func autoTracklist(
        query: String,
        url: String,
        duration: Int
    ) async throws -> APITracklist
    func parseTracklist(text: String, duration: Int) async throws -> APITracklist
    func submit(_ request: APIDownloadRequest) async throws -> String
    func submitSplit(_ request: APISplitDownloadRequest) async throws -> String
    func progress(jobID: String) -> AsyncThrowingStream<APIProgressEvent, Error>
    func job(jobID: String) async throws -> APIJobSnapshot
    func cancel(jobID: String) async throws -> APIJobSnapshot
}

enum SetlistAPIError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int, Data)
}

struct SetlistAPI: SetlistAPIProtocol, Sendable {
    let baseURL: URL
    let session: URLSession

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8765")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func resolve(url: String) async throws -> APIResolveResponse {
        try await post(
            path: ["resolve"],
            body: APIResolveRequest(url: url)
        )
    }

    func autoTracklist(
        query: String,
        url: String,
        duration: Int
    ) async throws -> APITracklist {
        try await post(
            path: ["auto-tracklist"],
            body: APIAutoTracklistRequest(
                query: query,
                url: url,
                duration: duration
            )
        )
    }

    func parseTracklist(
        text: String,
        duration: Int
    ) async throws -> APITracklist {
        try await post(
            path: ["parse-tracklist"],
            body: APIParseTracklistRequest(text: text, duration: duration)
        )
    }

    func submit(_ request: APIDownloadRequest) async throws -> String {
        let response: APIJobIDResponse = try await post(
            path: ["download"],
            body: request
        )
        return response.jobID
    }

    func submitSplit(
        _ request: APISplitDownloadRequest
    ) async throws -> String {
        let response: APIJobIDResponse = try await post(
            path: ["download-split"],
            body: request
        )
        return response.jobID
    }

    func progress(
        jobID: String
    ) -> AsyncThrowingStream<APIProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamingTask = Task {
                do {
                    var request = request(
                        path: ["progress", jobID],
                        method: "GET"
                    )
                    request.setValue(
                        "text/event-stream",
                        forHTTPHeaderField: "Accept"
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response: response)

                    var decoder = SSEDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for payload in decoder.append(Data([byte])) {
                            let event = try APIJSON.decoder.decode(
                                APIProgressEvent.self,
                                from: payload
                            )
                            if case .terminated = continuation.yield(event) {
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                streamingTask.cancel()
            }
        }
    }

    func job(jobID: String) async throws -> APIJobSnapshot {
        try await get(path: ["jobs", jobID])
    }

    func cancel(jobID: String) async throws -> APIJobSnapshot {
        try await postWithoutBody(path: ["jobs", jobID, "cancel"])
    }

    private func get<Response: Decodable & Sendable>(
        path: [String]
    ) async throws -> Response {
        let request = request(path: path, method: "GET")
        return try await send(request)
    }

    private func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        path: [String],
        body: Body
    ) async throws -> Response {
        var request = request(path: path, method: "POST")
        request.httpBody = try APIJSON.encoder.encode(body)
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        return try await send(request)
    }

    private func postWithoutBody<Response: Decodable & Sendable>(
        path: [String]
    ) async throws -> Response {
        let request = request(path: path, method: "POST")
        return try await send(request)
    }

    private func send<Response: Decodable & Sendable>(
        _ request: URLRequest
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try APIJSON.decoder.decode(Response.self, from: data)
    }

    private func request(
        path: [String],
        method: String
    ) -> URLRequest {
        let url = path.reduce(baseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(
        response: URLResponse,
        data: Data = Data()
    ) throws {
        guard let response = response as? HTTPURLResponse else {
            throw SetlistAPIError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw SetlistAPIError.httpStatus(response.statusCode, data)
        }
    }
}

private struct APIResolveRequest: Codable, Equatable, Sendable {
    let url: String
}

private struct APIAutoTracklistRequest: Codable, Equatable, Sendable {
    let query: String
    let url: String
    let duration: Int
}

private struct APIParseTracklistRequest: Codable, Equatable, Sendable {
    let text: String
    let duration: Int
}

private struct APIJobIDResponse: Codable, Equatable, Sendable {
    let jobID: String

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
    }
}

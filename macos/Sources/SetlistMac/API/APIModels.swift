import Foundation

enum APIJSON {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

struct APIMetadataFields: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var year: Int?
    var genre: String
    var comment: String
    var compilation: Bool

    init(
        title: String = "",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        year: Int? = nil,
        genre: String = "",
        comment: String = "",
        compilation: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.genre = genre
        self.comment = comment
        self.compilation = compilation
    }
}

struct APITrack: Codable, Equatable, Sendable {
    var start: Double?
    var title: String
    var artist: String
    var end: Double?

    init(
        start: Double? = nil,
        title: String = "",
        artist: String = "",
        end: Double? = nil
    ) {
        self.start = start
        self.title = title
        self.artist = artist
        self.end = end
    }
}

enum APITracklistSource: String, Codable, Equatable, Sendable {
    case chapters
    case description
    case manual
    case none
    case oneThousandOneTracklists = "1001tracklists"
}

struct APITracklist: Codable, Equatable, Sendable {
    var source: APITracklistSource
    var tracks: [APITrack]
    var album: String
    var albumArtist: String
    var note: String

    init(
        source: APITracklistSource = .none,
        tracks: [APITrack] = [],
        album: String = "",
        albumArtist: String = "",
        note: String = ""
    ) {
        self.source = source
        self.tracks = tracks
        self.album = album
        self.albumArtist = albumArtist
        self.note = note
    }
}

struct APIResolveResponse: Codable, Equatable, Sendable {
    var videoID: String
    var duration: Int
    var metadata: APIMetadataFields
    var cover: String
    var formats: String
    var detectedLine: String
    var hasChapters: Bool
    var tracklist: APITracklist?

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
        case duration
        case metadata
        case cover
        case formats
        case detectedLine
        case hasChapters
        case tracklist
    }
}

enum APIAudioFormat: String, Codable, Equatable, Sendable {
    case alac
    case aac256
}

struct APIDownloadRequest: Codable, Equatable, Sendable {
    var videoID: String
    var url: String
    var metadata: APIMetadataFields
    var format: APIAudioFormat
    var cover: String
    var callbackURL: String

    init(
        videoID: String,
        url: String,
        metadata: APIMetadataFields,
        format: APIAudioFormat = .alac,
        cover: String = "keep",
        callbackURL: String = ""
    ) {
        self.videoID = videoID
        self.url = url
        self.metadata = metadata
        self.format = format
        self.cover = cover
        self.callbackURL = callbackURL
    }

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
        case url
        case metadata
        case format
        case cover
        case callbackURL = "callbackUrl"
    }
}

struct APISplitDownloadRequest: Codable, Equatable, Sendable {
    var videoID: String
    var url: String
    var metadata: APIMetadataFields
    var tracks: [APITrack]
    var format: APIAudioFormat
    var cover: String
    var callbackURL: String

    init(
        videoID: String,
        url: String,
        metadata: APIMetadataFields,
        tracks: [APITrack],
        format: APIAudioFormat = .alac,
        cover: String = "keep",
        callbackURL: String = ""
    ) {
        self.videoID = videoID
        self.url = url
        self.metadata = metadata
        self.tracks = tracks
        self.format = format
        self.cover = cover
        self.callbackURL = callbackURL
    }

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
        case url
        case metadata
        case tracks
        case format
        case cover
        case callbackURL = "callbackUrl"
    }
}

enum APIProgressStage: String, Codable, Equatable, Sendable {
    case queued
    case download
    case encode
    case split
    case tag
    case done
    case error
    case cancelled
}

enum APITrackProgressState: String, Codable, Equatable, Sendable {
    case pending
    case cutting
    case tagging
    case ready
}

struct APIProgressEvent: Codable, Equatable, Sendable {
    var stage: APIProgressStage
    var pct: Double
    var stagePct: Double?
    var overallPct: Double?
    var message: String
    var trackIndex: Int?
    var trackCount: Int?
    var trackTitle: String?
    var trackState: APITrackProgressState?
    var downloadedBytes: Int?
    var totalBytes: Int?
    var speedBytesPerSecond: Double?
    var etaSeconds: Double?
    var filePath: String?

    var stagePercent: Double {
        stagePct ?? pct
    }

    var overallPercent: Double? {
        overallPct
    }

    init(
        stage: APIProgressStage,
        pct: Double = 0,
        stagePct: Double? = nil,
        overallPct: Double? = nil,
        message: String = "",
        trackIndex: Int? = nil,
        trackCount: Int? = nil,
        trackTitle: String? = nil,
        trackState: APITrackProgressState? = nil,
        downloadedBytes: Int? = nil,
        totalBytes: Int? = nil,
        speedBytesPerSecond: Double? = nil,
        etaSeconds: Double? = nil,
        filePath: String? = nil
    ) {
        self.stage = stage
        self.pct = pct
        self.stagePct = stagePct
        self.overallPct = overallPct
        self.message = message
        self.trackIndex = trackIndex
        self.trackCount = trackCount
        self.trackTitle = trackTitle
        self.trackState = trackState
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
        self.filePath = filePath
    }
}

enum APIJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case processing
    case cancelling
    case completed
    case failed
    case cancelled
    case interrupted
}

struct APIJobSnapshot: Codable, Equatable, Sendable {
    var jobID: String
    var status: APIJobStatus
    var latest: APIProgressEvent
    var outputPaths: [String]
    var error: String

    init(
        jobID: String,
        status: APIJobStatus,
        latest: APIProgressEvent,
        outputPaths: [String] = [],
        error: String = ""
    ) {
        self.jobID = jobID
        self.status = status
        self.latest = latest
        self.outputPaths = outputPaths
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case status
        case latest
        case outputPaths
        case error
    }
}

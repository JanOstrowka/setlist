import Foundation

enum DraftValidationIssue: Equatable, Sendable {
    case emptyTracklist
    case missingStart(trackIndex: Int)
    case startBeyondDuration(trackIndex: Int)
    case nonAscendingStart(trackIndex: Int)

    var message: String {
        switch self {
        case .emptyTracklist:
            "Add at least one track before splitting."
        case .missingStart(let index):
            "Track \(index + 1) needs a start time."
        case .startBeyondDuration(let index):
            "Track \(index + 1) starts after the set ends."
        case .nonAscendingStart(let index):
            "Track \(index + 1) starts before the previous track."
        }
    }
}

extension SetDraft {
    /// Applies a tracklist that arrived from a lookup (auto-find or
    /// paste) and adjusts the output defaults to match it: a set with a
    /// tracklist is meant to be split, and a set mixing different
    /// artists is tagged as a compilation so Music files it under
    /// various artists. Only turns options on — the user's explicit
    /// choices are never switched off.
    mutating func applyFetchedTracklist(_ fetched: APITracklist) {
        tracklist = fetched
        guard !fetched.tracks.isEmpty else {
            return
        }
        split = true
        if Self.hasVariousArtists(fetched.tracks) {
            metadata.compilation = true
        }
    }

    static func hasVariousArtists(_ tracks: [APITrack]) -> Bool {
        var artists = Set<String>()
        for track in tracks {
            let artist = track.artist
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !artist.isEmpty {
                artists.insert(artist)
            }
            if artists.count >= 2 {
                return true
            }
        }
        return false
    }

    mutating func moveTrack(from source: Int, to destination: Int) {
        guard tracklist.tracks.indices.contains(source),
              destination >= 0,
              destination <= tracklist.tracks.count else {
            return
        }
        var tracks = tracklist.tracks
        let track = tracks.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        tracks.insert(track, at: min(target, tracks.count))
        tracklist.tracks = tracks
        tracklist.source = .manual
    }

    mutating func addTrack(after index: Int? = nil) {
        var tracks = tracklist.tracks
        let insertionIndex = index.map { min($0 + 1, tracks.count) }
            ?? tracks.count
        tracks.insert(APITrack(), at: insertionIndex)
        tracklist.tracks = tracks
        tracklist.source = .manual
    }

    mutating func removeTrack(at index: Int) {
        guard tracklist.tracks.indices.contains(index) else {
            return
        }
        tracklist.tracks.remove(at: index)
        tracklist.source = .manual
    }

    var validationIssues: [DraftValidationIssue] {
        guard split else {
            return []
        }
        guard !tracklist.tracks.isEmpty else {
            return [.emptyTracklist]
        }

        var issues: [DraftValidationIssue] = []
        var previousStart: Double?
        for (index, track) in tracklist.tracks.enumerated() {
            guard let start = track.start else {
                issues.append(.missingStart(trackIndex: index))
                continue
            }
            if duration > 0, start >= Double(duration) {
                issues.append(.startBeyondDuration(trackIndex: index))
            }
            if let previousStart, start < previousStart {
                issues.append(.nonAscendingStart(trackIndex: index))
            }
            previousStart = start
        }
        return issues
    }

    var canStartProcessing: Bool {
        validationIssues.isEmpty
    }
}

enum TrackTime {
    /// Formats seconds as `m:ss` or `h:mm:ss`; nil becomes an empty string.
    static func format(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else {
            return ""
        }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Parses `s`, `m:ss`, or `h:mm:ss`; returns nil for anything else.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3, !parts.isEmpty else {
            return nil
        }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else {
                return nil
            }
            values.append(value)
        }
        // Non-leading components must be valid sexagesimal digits.
        for value in values.dropFirst() where value > 59 {
            return nil
        }
        return values.reduce(0.0) { $0 * 60 + Double($1) }
    }
}

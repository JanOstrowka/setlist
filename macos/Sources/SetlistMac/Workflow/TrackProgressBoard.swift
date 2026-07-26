import Foundation

/// Folds successive processing updates into a monotonic per-track status
/// board for the production scene. A track's status never regresses, and
/// activity on a later track implies all earlier tracks are ready.
struct TrackProgressBoard: Equatable, Sendable {
    enum TrackStatus: Int, Comparable, Sendable {
        case pending
        case cutting
        case tagging
        case ready

        static func < (lhs: TrackStatus, rhs: TrackStatus) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private(set) var statuses: [TrackStatus]

    init(trackCount: Int) {
        statuses = Array(repeating: .pending, count: max(0, trackCount))
    }

    var readyCount: Int {
        statuses.count { $0 == .ready }
    }

    var activeIndex: Int? {
        statuses.firstIndex { $0 == .cutting || $0 == .tagging }
    }

    mutating func apply(_ processing: ProcessingState) {
        switch processing.stage {
        case .done:
            markAllReady()
            return
        case .resolving, .reviewing, .submitting, .queued, .download,
             .encode, .error, .cancelled, .unknown:
            break
        case .split, .tag:
            break
        }

        guard let index = processing.trackIndex,
              statuses.indices.contains(index) else {
            return
        }

        // A track being worked on means every earlier track is finished.
        for earlier in 0..<index {
            raise(earlier, to: .ready)
        }

        switch processing.trackState {
        case .cutting:
            raise(index, to: .cutting)
        case .tagging:
            raise(index, to: .tagging)
        case .ready:
            raise(index, to: .ready)
        case .pending, nil:
            break
        }
    }

    private mutating func markAllReady() {
        for index in statuses.indices {
            statuses[index] = .ready
        }
    }

    private mutating func raise(_ index: Int, to status: TrackStatus) {
        if statuses[index] < status {
            statuses[index] = status
        }
    }
}

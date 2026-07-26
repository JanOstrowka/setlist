import Foundation

/// Decides how the app should respond to a quit request based on the
/// active workflow. Resolving and processing hold real work that must be
/// confirmed and cancelled cleanly before termination.
struct TerminationPolicy: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case terminateNow
        case confirmCancellation
    }

    let action: Action

    init(state: WorkflowState) {
        switch state {
        case .resolving, .processing:
            action = .confirmCancellation
        case .idle, .reviewing, .completed, .failed:
            action = .terminateNow
        }
    }
}

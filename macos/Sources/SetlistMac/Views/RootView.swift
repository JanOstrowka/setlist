import AppKit
import SwiftUI

struct RootView: View {
    @Bindable private var environment: SetlistAppEnvironment
    @ObservedObject private var backend: BackendController

    init(environment: SetlistAppEnvironment) {
        _environment = Bindable(wrappedValue: environment)
        _backend = ObservedObject(wrappedValue: environment.backend)
    }

    private var selectedRecord: HistoryRecord? {
        guard let selectedRecordID = environment.selectedRecordID else {
            return nil
        }
        return environment.history.records.first {
            $0.id == selectedRecordID
        }
    }

    var body: some View {
        NavigationSplitView {
            RecentSidebar(
                records: environment.history.records,
                selection: $environment.selectedRecordID,
                newSet: startOver
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 320)
        } detail: {
            detail
                .frame(minWidth: 700, minHeight: 560)
        }
        .task {
            await backend.start()
        }
        .toolbar {
            ToolbarItem {
                Button("New Set", systemImage: "plus") {
                    startOver()
                }
                .help("New Set (⌘N)")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch backend.status {
        case .idle, .starting:
            EngineStartupView(status: backend.status)
        case .failed(let message):
            EngineFailureView(
                message: message,
                projectRoot: backend.configuration.projectRoot,
                retry: backend.retry
            )
        case .ready:
            if let selectedRecord {
                HistoryDetailView(
                    record: selectedRecord,
                    retry: { url in
                        environment.selectedRecordID = nil
                        Task {
                            await environment.workflow.resolve(url)
                        }
                    }
                )
            } else {
                WorkflowDetailView(
                    workflow: environment.workflow,
                    records: environment.history.records
                )
            }
        }
    }

    private func startOver() {
        environment.startNewSet()
    }
}

private struct WorkflowDetailView: View {
    let workflow: WorkflowController
    let records: [HistoryRecord]

    var body: some View {
        switch workflow.state {
        case .idle:
            LandingView { url in
                Task {
                    await workflow.resolve(url)
                }
            }
        case .resolving(let phase):
            ResolveLoadingView(sourceURL: phase.sourceURL)
                .transition(.opacity)
        case .reviewing(let draft):
            ReviewView(workflow: workflow, draft: draft)
                .transition(.opacity)
        case .processing(let processing):
            ProcessingView(workflow: workflow, processing: processing)
                .transition(.opacity)
        case .completed(let completed):
            MilestoneStatusView(
                eyebrow: "COMPLETE",
                title: "The set is on disk",
                detail: completed.outputPaths.isEmpty
                    ? "Processing finished."
                    : "\(completed.outputPaths.count) output file\(completed.outputPaths.count == 1 ? "" : "s") saved.",
                status: completed.completedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                ),
                actionTitle: "Start Another Set",
                action: workflow.startOver
            )
        case .failed(let failure):
            let record = failure.recordID.flatMap { id in
                records.first { $0.id == id }
            }
            MilestoneStatusView(
                eyebrow: "NEEDS ATTENTION",
                title: "This set stopped",
                detail: failure.message,
                status: failure.failedAt.formatted(
                    date: .omitted,
                    time: .shortened
                ),
                actionTitle: record == nil ? "Start Another Set" : "Retry",
                action: {
                    if let sourceURL = record?.sourceURL {
                        Task {
                            await workflow.resolve(sourceURL)
                        }
                    } else {
                        workflow.startOver()
                    }
                }
            )
        }
    }
}

private struct EngineStartupView: View {
    let status: BackendStatus

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            VStack(alignment: .leading, spacing: 24) {
                Text("LOCAL ENGINE")
                    .font(.caption.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(SetlistTheme.cherry)
                Text("Warming the studio")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(SetlistTheme.paper)
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SetlistTheme.cherry)
                    Text(
                        status == .idle
                            ? "Preparing the local media engine…"
                            : "Starting the local media engine…"
                    )
                    .foregroundStyle(SetlistTheme.mutedPaper)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(SetlistTheme.detailPadding)
        }
    }
}

private struct EngineFailureView: View {
    let message: String
    let projectRoot: URL
    let retry: () -> Void

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            VStack(alignment: .leading, spacing: 22) {
                Text("ENGINE OFFLINE")
                    .font(.caption.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(SetlistTheme.cherry)
                Text("The studio needs attention")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(SetlistTheme.paper)
                Text(message)
                    .font(.body)
                    .foregroundStyle(SetlistTheme.mutedPaper)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)

                GlassEffectContainer(spacing: 16) {
                    HStack(spacing: 10) {
                        Button("Show Project in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                projectRoot
                            ])
                        }
                        Button("Try Again", action: retry)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(10)
                    .glassEffect(.regular, in: .capsule)
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(SetlistTheme.detailPadding)
        }
    }
}

private struct HistoryDetailView: View {
    let record: HistoryRecord
    let retry: (String) -> Void

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 11) {
                    Text(record.status.sidebarTitle.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(2.2)
                        .foregroundStyle(record.status.tint)

                    Text(record.title.isEmpty ? "Untitled set" : record.title)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(SetlistTheme.paper)

                    if !record.artist.isEmpty {
                        Text(record.artist)
                            .font(.title3)
                            .foregroundStyle(SetlistTheme.mutedPaper)
                    }
                }

                Divider()
                    .overlay(SetlistTheme.hairline)

                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 14) {
                    historyRow(
                        label: "Last activity",
                        value: record.updatedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    historyRow(label: "Source", value: record.sourceURL)
                    if let stage = record.stage {
                        historyRow(label: "Stage", value: stage.displayTitle)
                    }
                    if let error = record.errorSummary, !error.isEmpty {
                        historyRow(label: "Status note", value: error)
                    }
                }

                if [.failed, .cancelled, .interrupted].contains(record.status) {
                    Button("Retry Set") {
                        retry(record.sourceURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SetlistTheme.cherry)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(SetlistTheme.detailPadding)
        }
    }

    private func historyRow(label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(SetlistTheme.mutedPaper.opacity(0.72))
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(SetlistTheme.paper)
                .textSelection(.enabled)
        }
    }
}

private struct MilestoneStatusView: View {
    let eyebrow: String
    let title: String
    let detail: String
    let status: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        ZStack {
            SetlistDetailBackground()

            VStack(alignment: .leading, spacing: 20) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(SetlistTheme.cherry)
                Text(title)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(SetlistTheme.paper)
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(SetlistTheme.mutedPaper)
                    .frame(maxWidth: 620, alignment: .leading)
                Text(status)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SetlistTheme.paper.opacity(0.8))
                    .padding(.top, 8)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .tint(SetlistTheme.cherry)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(SetlistTheme.detailPadding)
        }
    }
}

extension HistoryStage {
    var displayTitle: String {
        switch self {
        case .resolving:
            "Resolving"
        case .reviewing:
            "Reviewing"
        case .submitting:
            "Submitting"
        case .queued:
            "Queued"
        case .download:
            "Download"
        case .encode:
            "Encode"
        case .split:
            "Split"
        case .tag:
            "Tag"
        case .done:
            "Complete"
        case .error:
            "Error"
        case .cancelled:
            "Cancelled"
        case .unknown:
            "Unknown"
        }
    }
}

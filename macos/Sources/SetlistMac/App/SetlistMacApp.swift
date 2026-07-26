import AppKit
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SetlistAppEnvironment {
    let backend: BackendController
    let modelContainer: ModelContainer
    let history: HistoryStore
    let workflow: WorkflowController
    let musicImporter: any MusicImporting
    var selectedRecordID: UUID?

    init(
        backend: BackendController,
        modelContainer: ModelContainer,
        history: HistoryStore,
        workflow: WorkflowController,
        musicImporter: any MusicImporting = AppleMusicImporter()
    ) {
        self.backend = backend
        self.modelContainer = modelContainer
        self.history = history
        self.workflow = workflow
        self.musicImporter = musicImporter
    }

    static func live() throws -> SetlistAppEnvironment {
        let backend = BackendController.shared
        let modelContainer = try ModelContainer(for: HistoryRecord.self)
        let history = try HistoryStore(modelContext: modelContainer.mainContext)
        let api = SetlistAPI(baseURL: backend.configuration.baseURL)
        let workflow = WorkflowController(api: api, history: history)
        return SetlistAppEnvironment(
            backend: backend,
            modelContainer: modelContainer,
            history: history,
            workflow: workflow
        )
    }

    func startNewSet() {
        selectedRecordID = nil
        workflow.startOver()
    }
}

@main
struct SetlistMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment: SetlistAppEnvironment

    init() {
        do {
            environment = try SetlistAppEnvironment.live()
        } catch {
            fatalError("Could not create Setlist storage: \(error)")
        }
        AppDelegate.environment = environment
    }

    var body: some Scene {
        Window("Setlist", id: "setlist") {
            RootView(environment: environment)
                .modelContainer(environment.modelContainer)
                .preferredColorScheme(.dark)
                .tint(SetlistTheme.cherry)
        }
        .defaultSize(width: 1_180, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            SetlistCommands(environment: environment)
        }

        MenuBarExtra {
            SetlistMenu(environment: environment)
        } label: {
            Label("Setlist", systemImage: environment.backend.status.symbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct SetlistCommands: Commands {
    let environment: SetlistAppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Set") {
                environment.startNewSet()
                openSetlist()
            }
            .keyboardShortcut("n")

            Button("Open Setlist") {
                openSetlist()
            }
            .keyboardShortcut("o")
        }
    }

    private func openSetlist() {
        openWindow(id: "setlist")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SetlistMenu: View {
    let environment: SetlistAppEnvironment
    @ObservedObject private var backend: BackendController
    @Environment(\.openWindow) private var openWindow

    init(environment: SetlistAppEnvironment) {
        self.environment = environment
        _backend = ObservedObject(wrappedValue: environment.backend)
    }

    var body: some View {
        Text("Setlist · \(backend.status.title)")

        Button("Open Setlist") {
            openSetlist()
        }
        .keyboardShortcut("o")

        Button("New Set") {
            environment.startNewSet()
            openSetlist()
        }
        .keyboardShortcut("n")

        if case .failed = backend.status {
            Button("Try Starting Again") {
                backend.retry()
            }
        }

        if backend.ownsBackend {
            Button("Stop Local Server") {
                backend.stop()
            }
        } else if backend.status == .idle {
            Button("Start Local Server") {
                backend.retry()
            }
        }

        Divider()

        Button("Show Project in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([
                backend.configuration.projectRoot
            ])
        }

        Divider()

        Button("Quit Setlist") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openSetlist() {
        openWindow(id: "setlist")
        NSApp.activate(ignoringOtherApps: true)
    }
}

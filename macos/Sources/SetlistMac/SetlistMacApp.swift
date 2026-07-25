import AppKit
import SwiftUI

@main
struct SetlistMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend = BackendController.shared

    var body: some Scene {
        Window("Setlist", id: "setlist") {
            SetlistWindow(backend: backend)
        }
        .defaultSize(width: 1_180, height: 820)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            SetlistMenu(backend: backend)
        } label: {
            Label("Setlist", systemImage: backend.status.symbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendController.shared.stop()
    }
}

private struct SetlistWindow: View {
    @ObservedObject var backend: BackendController

    var body: some View {
        Group {
            switch backend.status {
            case .ready:
                WebView(url: backend.configuration.baseURL)
            case .idle, .starting:
                StartupView(status: backend.status)
            case .failed(let message):
                FailureView(message: message) {
                    backend.retry()
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await backend.start()
        }
    }
}

private struct StartupView: View {
    let status: BackendStatus

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.10),
                    Color(red: 0.15, green: 0.05, blue: 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 86, height: 86)
                    .background(.red.gradient, in: RoundedRectangle(cornerRadius: 24))

                Text("Setlist")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                ProgressView()
                    .controlSize(.small)
                    .tint(.white)

                Text(status == .idle ? "Preparing local server…" : status.title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Setlist couldn’t start")
                .font(.title2.bold())

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 520)

            HStack {
                Button("Show Project in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        backendRoot
                    ])
                }
                Button("Try Again", action: retry)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
    }

    private var backendRoot: URL {
        BackendController.shared.configuration.projectRoot
    }
}

private struct SetlistMenu: View {
    @ObservedObject var backend: BackendController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Setlist · \(backend.status.title)")

        Button("Open Setlist") {
            openWindow(id: "setlist")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        .disabled(backend.status != .ready)

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
}

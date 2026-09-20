import AppKit
import SwiftUI

/// Edits the engine's settings file. Saving rewrites only the keys shown
/// here and restarts an app-owned engine so the change takes effect.
struct SettingsView: View {
    @ObservedObject private var backend: BackendController
    @State private var draft: SettingsDraft
    @State private var saveState: SaveState = .idle

    init(backend: BackendController) {
        _backend = ObservedObject(wrappedValue: backend)
        _draft = State(initialValue: SettingsDraft(from: backend.configuration.settings()))
    }

    var body: some View {
        Form {
            Section {
                // No textContentType: an API key is not a login password,
                // and the .password type summons the Passwords autofill UI.
                SecureField("OpenAI API key", text: $draft.openAIKey, prompt: Text("sk-…"))
                    .autocorrectionDisabled()
                TextField("Model", text: $draft.openAIModel, prompt: Text("gpt-4o-mini"))
                    .autocorrectionDisabled()
            } header: {
                Text("Metadata")
            } footer: {
                Text(
                    "Optional. With a key, Setlist asks OpenAI to clean up titles, "
                        + "artists, albums, and genres. Without one it parses the video title."
                )
            }

            Section {
                LabeledContent("Save finished sets to") {
                    HStack(spacing: 8) {
                        Text(draft.outputDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseOutputDirectory)
                    }
                }
                Picker("Default format", selection: $draft.defaultFormat) {
                    Text("ALAC (lossless, larger)").tag("alac")
                    Text("AAC 256 kbps (smaller)").tag("aac256")
                }
            } header: {
                Text("Library")
            } footer: {
                Text(
                    "Files are organized as Artist/Set/NN - Track.m4a with a "
                        + "square cover, ready for Apple Music."
                )
            }

            Section {
                LabeledContent("Engine", value: backend.status.title)
                LabeledContent("Settings file") {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            backend.configuration.settingsFileURL
                        ])
                    } label: {
                        Text(backend.configuration.settingsFileURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                }
                HStack {
                    Button("Show Engine Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            backend.configuration.logFileURL
                        ])
                    }
                    Button("Restart Engine") {
                        backend.retry()
                    }
                }
            } header: {
                Text("Engine")
            }

            HStack {
                statusLabel
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isDirty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Setlist Settings")
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .saved(let restarted):
            Label(
                restarted
                    ? "Saved. Restarting the engine…"
                    : "Saved. Restart the engine to apply.",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.directoryURL = backend.configuration.outputDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        draft.outputDirectory = SettingsDraft.abbreviatingHome(url.path)
    }

    private func save() {
        var file = backend.configuration.settings()
        draft.apply(to: &file)
        do {
            try file.write(to: backend.configuration.settingsFileURL)
        } catch {
            saveState = .failed("Could not save: \(error.localizedDescription)")
            return
        }
        draft.markSaved()
        // Only an engine we launched can be restarted from here; a
        // developer's `./run.sh` session picks the change up on its own.
        let restarted = backend.ownsBackend
        if restarted {
            backend.retry()
        }
        saveState = .saved(restarted: restarted)
    }

    private enum SaveState {
        case idle
        case saved(restarted: Bool)
        case failed(String)
    }
}

/// The editable subset of the settings file, with change tracking.
struct SettingsDraft: Equatable {
    var openAIKey: String
    var openAIModel: String
    var outputDirectory: String
    var defaultFormat: String
    private var saved: Snapshot

    private struct Snapshot: Equatable {
        var openAIKey: String
        var openAIModel: String
        var outputDirectory: String
        var defaultFormat: String
    }

    static let defaultOutputDirectory = "~/Music/YouTube Sets"

    init(from file: EnvFile) {
        openAIKey = file.value(for: "OPENAI_API_KEY") ?? ""
        openAIModel = file.value(for: "OPENAI_MODEL") ?? ""
        let output = file.value(for: "OUTPUT_DIR") ?? ""
        outputDirectory = output.isEmpty ? Self.defaultOutputDirectory : output
        let format = file.value(for: "DEFAULT_FORMAT") ?? ""
        defaultFormat = format == "aac256" ? "aac256" : "alac"
        saved = Snapshot(
            openAIKey: openAIKey,
            openAIModel: openAIModel,
            outputDirectory: outputDirectory,
            defaultFormat: defaultFormat
        )
    }

    var isDirty: Bool {
        saved != Snapshot(
            openAIKey: openAIKey,
            openAIModel: openAIModel,
            outputDirectory: outputDirectory,
            defaultFormat: defaultFormat
        )
    }

    mutating func markSaved() {
        saved = Snapshot(
            openAIKey: openAIKey,
            openAIModel: openAIModel,
            outputDirectory: outputDirectory,
            defaultFormat: defaultFormat
        )
    }

    /// Writes the draft into `file`, leaving unrelated keys alone.
    func apply(to file: inout EnvFile) {
        file.set(openAIKey.trimmingCharacters(in: .whitespaces), for: "OPENAI_API_KEY")
        let model = openAIModel.trimmingCharacters(in: .whitespaces)
        file.set(model.isEmpty ? "gpt-4o-mini" : model, for: "OPENAI_MODEL")
        let output = outputDirectory.trimmingCharacters(in: .whitespaces)
        file.set(output.isEmpty ? Self.defaultOutputDirectory : output, for: "OUTPUT_DIR")
        file.set(defaultFormat, for: "DEFAULT_FORMAT")
    }

    /// `/Users/me/Music/X` → `~/Music/X`, so the file stays portable and
    /// readable.
    static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") || path == home else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }
}

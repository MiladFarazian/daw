import SwiftUI

@main
struct GosanApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var taste: TasteEngine
    @StateObject private var project: ProjectStore
    @StateObject private var preview = PreviewPlayer()
    @StateObject private var recorder = Recorder()

    init() {
        let settings = AppSettings()
        let taste = TasteEngine()
        let recorder = Recorder()
        _settings = StateObject(wrappedValue: settings)
        _taste = StateObject(wrappedValue: taste)
        _recorder = StateObject(wrappedValue: recorder)
        _project = StateObject(wrappedValue: ProjectStore(settings: settings, taste: taste, recorder: recorder))
    }

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(project)
                .environmentObject(settings)
                .environmentObject(preview)
                .environmentObject(taste)
                .environmentObject(recorder)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { project.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!project.canUndo)
                Button("Redo") { project.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!project.canRedo)
            }
            CommandMenu("Transport") {
                Button(project.isPlaying ? "Stop" : "Play") { project.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Return to Start") { project.seek(to: 0) }
                    .keyboardShortcut(.home, modifiers: [])
                Button("Go to End") { project.seek(to: project.totalDuration) }
                    .keyboardShortcut(.end, modifiers: [])
                Divider()
                Button("Nudge Back 1s") { project.seek(to: max(0, project.currentTime - 1)) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Nudge Forward 1s") { project.seek(to: project.currentTime + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Divider()
                Button(project.loopEnabled ? "Disable Loop" : "Enable Loop") { project.toggleLoop() }
                    .keyboardShortcut("l", modifiers: .command)
                Button(project.metronomeEnabled ? "Metronome Off" : "Metronome On") {
                    project.metronomeEnabled.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Open Mixer") { project.activeSheet = .mixer }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { project.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Menu("New from Template") {
                    Button("Beat + Vocal") { project.newFromTemplate(["Beat", "Vocal"]) }
                    Button("Full Band") { project.newFromTemplate(["Drums", "Bass", "Keys", "Vocal", "Lead"]) }
                    Button("Two-Mic / Podcast") { project.newFromTemplate(["Mic 1", "Mic 2"]) }
                }
                Button("Open…") { project.openProject() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(settings.recentProjects, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) {
                            project.openProjectAt(URL(fileURLWithPath: path))
                        }
                    }
                    if !settings.recentProjects.isEmpty {
                        Divider()
                        Button("Clear Menu") { settings.recentProjects = [] }
                    }
                }
                .disabled(settings.recentProjects.isEmpty)
                Divider()
                Button("Save…") { project.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(taste)
        }
    }
}

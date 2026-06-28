import SwiftUI

@main
struct DawApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var taste: TasteEngine
    @StateObject private var project: ProjectStore
    @StateObject private var preview = PreviewPlayer()

    init() {
        let settings = AppSettings()
        let taste = TasteEngine()
        _settings = StateObject(wrappedValue: settings)
        _taste = StateObject(wrappedValue: taste)
        _project = StateObject(wrappedValue: ProjectStore(settings: settings, taste: taste))
    }

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(project)
                .environmentObject(settings)
                .environmentObject(preview)
                .environmentObject(taste)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(taste)
        }
    }
}

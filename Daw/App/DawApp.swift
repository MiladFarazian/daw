import SwiftUI

@main
struct DawApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var project: ProjectStore
    @StateObject private var preview = PreviewPlayer()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _project = StateObject(wrappedValue: ProjectStore(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(project)
                .environmentObject(settings)
                .environmentObject(preview)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

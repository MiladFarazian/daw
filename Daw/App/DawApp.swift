import SwiftUI

@main
struct DawApp: App {
    @StateObject private var project = ProjectStore()

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(project)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

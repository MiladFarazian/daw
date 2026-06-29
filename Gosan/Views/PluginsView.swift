import SwiftUI
import AVFoundation
import AppKit
import CoreAudioKit

/// Manage a track's inserted Audio Unit plugins: add from the installed list,
/// remove, and open each plugin's native editor.
struct PluginsView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID

    @State private var available: [PluginHost.AvailableAU] = []
    @State private var openPlugin: OpenPlugin?

    private struct OpenPlugin: Identifiable { let id: Int; let name: String }
    private var track: Track? { project.tracks.first { $0.id == trackID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Plugins — \(track?.name ?? "")", systemImage: "puzzlepiece.extension").font(.headline)
                Spacer()
                Menu("Add Plugin") {
                    if available.isEmpty {
                        Text("Scanning…")
                    } else {
                        ForEach(available) { au in
                            Button("\(au.name) — \(au.manufacturerName)") {
                                if let track { project.addPlugin(PluginHost.ref(for: au), to: track) }
                            }
                        }
                    }
                }
                .frame(width: 150)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            if let track, !track.plugins.isEmpty {
                List {
                    ForEach(Array(track.plugins.enumerated()), id: \.element.id) { index, ref in
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
                            Text(ref.name)
                            Spacer()
                            Button("Open") { openPlugin = OpenPlugin(id: index, name: ref.name) }
                            Button(role: .destructive) { project.removePlugin(at: index, from: track) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("No plugins on this track yet.\nAdd an Audio Unit effect above — it inserts after the built-in FX.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 340)
        .onAppear {
            if available.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async {
                    let effects = PluginHost.availableEffects()
                    DispatchQueue.main.async { available = effects }
                }
            }
        }
        .sheet(item: $openPlugin) { plugin in
            VStack(spacing: 0) {
                HStack {
                    Text(plugin.name).font(.headline)
                    Spacer()
                    Button("Close") { openPlugin = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                if let unit = project.pluginUnit(trackID: trackID, index: plugin.id) {
                    AUViewHost(unit: unit).frame(minWidth: 500, minHeight: 320)
                } else {
                    Text("This plugin has no custom editor, or isn't loaded.")
                        .foregroundStyle(.secondary)
                        .frame(width: 500, height: 220)
                }
            }
        }
    }
}

/// Hosts an Audio Unit's native view controller (AUv3 custom UI; generic fallback otherwise).
struct AUViewHost: NSViewControllerRepresentable {
    let unit: AVAudioUnit

    func makeNSViewController(context: Context) -> NSViewController {
        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        unit.auAudioUnit.requestViewController { vc in
            DispatchQueue.main.async {
                guard let vc else { return }
                container.addChild(vc)
                vc.view.frame = container.view.bounds
                vc.view.autoresizingMask = [.width, .height]
                container.view.addSubview(vc.view)
            }
        }
        return container
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

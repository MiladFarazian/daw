// Capture a live app window to PNG via ScreenCaptureKit — works even when the window
// is on another Space (onScreenWindowsOnly: false). Lets the agent see the real
// rendered UI for iteration.  usage: swift capture-window.swift <pid> <out.png>
import ScreenCaptureKit
import AppKit
import Foundation

guard CommandLine.arguments.count >= 3, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: capture-window.swift <pid> <out.png>"); exit(1)
}
let outPath: String = CommandLine.arguments[2]

// Connect to the window server / init CoreGraphics (SCK + CGImage need this).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func pickWindow(_ windows: [SCWindow], pid: Int32) -> SCWindow? {
    var candidates: [SCWindow] = []
    for w in windows {
        guard w.owningApplication?.processID == pid else { continue }
        if w.frame.width > 300 && w.frame.height > 200 { candidates.append(w) }
    }
    candidates.sort { (a, b) -> Bool in
        let areaA: CGFloat = a.frame.width * a.frame.height
        let areaB: CGFloat = b.frame.width * b.frame.height
        return areaA > areaB
    }
    return candidates.first
}

func capture(_ window: SCWindow, to path: String) async throws {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * 2)
    config.height = Int(window.frame.height * 2)
    config.showsCursor = false
    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let png = rep.representation(using: .png, properties: [:]) else { print("ENCODE_FAILED"); return }
    try png.write(to: URL(fileURLWithPath: path))
    print("CAPTURED \(Int(window.frame.width))x\(Int(window.frame.height)) -> \(path)")
}

func run() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // Capture every sizeable window the app owns (main window + any open sheet), largest first.
        var windows: [SCWindow] = []
        for w in content.windows where w.owningApplication?.processID == pid {
            if w.frame.width > 300 && w.frame.height > 180 { windows.append(w) }
        }
        windows.sort { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
        guard !windows.isEmpty else { print("NO_WINDOW"); return }
        let base = (outPath as NSString).deletingPathExtension
        for (i, w) in windows.enumerated() {
            let path = i == 0 ? outPath : "\(base)_\(i).png"
            try await capture(w, to: path)
        }
    } catch {
        print("ERROR \(error)")
    }
}

Task {
    await run()
    CFRunLoopStop(CFRunLoopGetMain())
}
CFRunLoopRun()

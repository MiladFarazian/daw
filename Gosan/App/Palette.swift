import SwiftUI

/// Track colors, cycled by index.
enum Palette {
    static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// Formats a time interval as mm:ss.cc for the transport and ruler.
func timecode(_ time: TimeInterval) -> String {
    let total = max(0, time)
    let minutes = Int(total) / 60
    let seconds = Int(total) % 60
    let centiseconds = Int((total - floor(total)) * 100)
    return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
}

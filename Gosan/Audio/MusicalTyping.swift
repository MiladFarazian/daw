import Foundation

/// Maps the computer keyboard to MIDI notes (GarageBand "Musical Typing" layout),
/// so you can play software instruments without a MIDI controller.
enum MusicalTyping {
    /// keyCode → semitone offset from C of the current octave (US layout).
    private static let offsets: [UInt16: Int] = [
        0: 0,    // A  → C
        13: 1,   // W  → C#
        1: 2,    // S  → D
        14: 3,   // E  → D#
        2: 4,    // D  → E
        3: 5,    // F  → F
        17: 6,   // T  → F#
        5: 7,    // G  → G
        16: 8,   // Y  → G#
        4: 9,    // H  → A
        32: 10,  // U  → A#
        38: 11,  // J  → B
        40: 12,  // K  → C (next octave)
        31: 13,  // O  → C#
        37: 14,  // L  → D
        35: 15,  // P  → D#
        41: 16   // ;  → E
    ]
    static let octaveDownKey: UInt16 = 6   // Z
    static let octaveUpKey: UInt16 = 7     // X

    /// True if this key is part of the musical-typing layout (note or octave shift).
    static func isMusicalKey(_ keyCode: UInt16) -> Bool {
        offsets[keyCode] != nil || keyCode == octaveDownKey || keyCode == octaveUpKey
    }

    /// MIDI pitch for a note key at `octave` (nil for non-note keys / out of range).
    static func pitch(keyCode: UInt16, octave: Int) -> Int? {
        guard let offset = offsets[keyCode] else { return nil }
        let pitch = (octave + 1) * 12 + offset
        return (0...127).contains(pitch) ? pitch : nil
    }
}

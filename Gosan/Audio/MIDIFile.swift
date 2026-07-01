import Foundation

/// Read/write Standard MIDI Files (.mid, format 0). Pure → unit-testable via round-trip.
enum MIDIFile {
    private static let division = 480   // ticks per quarter note

    private static func vlq(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { out.insert(UInt8((v & 0x7F) | 0x80), at: 0); v >>= 7 }
        return out
    }

    /// Serialize notes to a one-track SMF at `tempo` BPM.
    static func write(notes: [MIDINote], tempo: Double, channel: UInt8 = 0) -> Data {
        func ticks(_ seconds: Double) -> Int { Int((seconds * tempo / 60.0 * Double(division)).rounded()) }

        struct Ev { let tick: Int; let bytes: [UInt8]; let onset: Bool }
        var events: [Ev] = []
        for note in notes {
            let pitch = UInt8(max(0, min(127, note.pitch)))
            events.append(Ev(tick: ticks(note.start),
                             bytes: [0x90 | channel, pitch, UInt8(max(1, min(127, note.velocity)))], onset: true))
            events.append(Ev(tick: ticks(note.start + note.duration),
                             bytes: [0x80 | channel, pitch, 0], onset: false))
        }
        // Stable order: earlier tick first; at equal ticks, note-offs before note-ons.
        events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : (!$0.onset && $1.onset) }

        var track: [UInt8] = []
        let mpq = Int(60_000_000.0 / max(1, tempo))   // microseconds per quarter
        track += vlq(0) + [0xFF, 0x51, 0x03, UInt8((mpq >> 16) & 0xFF), UInt8((mpq >> 8) & 0xFF), UInt8(mpq & 0xFF)]
        var last = 0
        for ev in events { track += vlq(ev.tick - last) + ev.bytes; last = ev.tick }
        track += vlq(0) + [0xFF, 0x2F, 0x00]   // end of track

        var data: [UInt8] = Array("MThd".utf8)
        data += [0, 0, 0, 6, 0, 0, 0, 1, UInt8((division >> 8) & 0xFF), UInt8(division & 0xFF)]
        data += Array("MTrk".utf8)
        let len = track.count
        data += [UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        data += track
        return Data(data)
    }

    /// Parse an SMF into notes + its tempo. Handles running status; ignores non-note events.
    static func read(_ data: Data) -> (notes: [MIDINote], tempo: Double)? {
        let bytes = [UInt8](data)
        guard bytes.count > 14, String(bytes: bytes[0..<4], encoding: .ascii) == "MThd" else { return nil }
        var i = 8
        func u16() -> Int { let v = (Int(bytes[i]) << 8) | Int(bytes[i + 1]); i += 2; return v }
        func u32() -> Int { let v = (Int(bytes[i]) << 24) | (Int(bytes[i+1]) << 16) | (Int(bytes[i+2]) << 8) | Int(bytes[i+3]); i += 4; return v }
        _ = u16()                       // format
        let ntracks = max(1, u16())
        let division = max(1, u16())

        var tempo = 120.0
        var notes: [MIDINote] = []

        for _ in 0..<ntracks {
            guard i + 8 <= bytes.count, String(bytes: bytes[i..<i+4], encoding: .ascii) == "MTrk" else { break }
            i += 4
            let trackLen = u32()
            let end = min(bytes.count, i + trackLen)
            var tick = 0
            var status: UInt8 = 0
            var active: [Int: (tick: Int, vel: Int)] = [:]
            func vlqRead() -> Int { var v = 0; while i < end { let b = bytes[i]; i += 1; v = (v << 7) | Int(b & 0x7F); if b & 0x80 == 0 { break } }; return v }
            func sec(_ t: Int) -> Double { Double(t) / Double(division) * (60.0 / tempo) }

            while i < end {
                tick += vlqRead()
                guard i < end else { break }
                if bytes[i] & 0x80 != 0 { status = bytes[i]; i += 1 }   // else running status
                let cmd = status & 0xF0
                if status == 0xFF {
                    let type = bytes[i]; i += 1
                    let mlen = vlqRead()
                    if type == 0x51, mlen == 3, i + 2 < end {
                        let mpq = (Int(bytes[i]) << 16) | (Int(bytes[i+1]) << 8) | Int(bytes[i+2])
                        if mpq > 0 { tempo = 60_000_000.0 / Double(mpq) }
                    }
                    i += mlen
                } else if status == 0xF0 || status == 0xF7 {
                    i += vlqRead()
                } else if cmd == 0x90 || cmd == 0x80 {
                    guard i + 1 < end else { break }
                    let pitch = Int(bytes[i]); let vel = Int(bytes[i + 1]); i += 2
                    if cmd == 0x90 && vel > 0 {
                        active[pitch] = (tick, vel)
                    } else if let onset = active.removeValue(forKey: pitch) {
                        let start = sec(onset.tick)
                        notes.append(MIDINote(pitch: pitch, start: start,
                                              duration: max(0.02, sec(tick) - start), velocity: onset.vel))
                    }
                } else if cmd == 0xC0 || cmd == 0xD0 {
                    i += 1
                } else {   // 0xA0/0xB0/0xE0
                    i += 2
                }
            }
            i = end
        }
        return (notes.sorted { $0.start < $1.start }, tempo)
    }
}

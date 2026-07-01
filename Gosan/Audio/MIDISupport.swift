import AVFoundation
import AudioToolbox

/// Helpers for instrument (MIDI) tracks: Apple's built-in General-MIDI DLS synth
/// (no soundfont required) and raw MIDI event sending.
enum MIDISupport {
    /// Instantiate the built-in DLS General-MIDI synth. Blocking (offline-safe).
    static func makeDLSSynth() -> AVAudioUnit? {
        let cd = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                           componentSubType: kAudioUnitSubType_DLSSynth,
                                           componentManufacturer: kAudioUnitManufacturer_Apple,
                                           componentFlags: 0, componentFlagsMask: 0)
        var result: AVAudioUnit?
        let sem = DispatchSemaphore(value: 0)
        AVAudioUnit.instantiate(with: cd, options: []) { unit, _ in
            result = unit
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return result
    }

    /// The synth for an instrument track: its chosen AU instrument, else the built-in GM synth.
    /// Drum tracks always use the built-in GM drum kit (channel 9).
    static func makeInstrument(for track: Track) -> AVAudioUnit? {
        if !track.isDrumKit, let ref = track.instrumentPlugin, let au = PluginHost.instantiate(ref) {
            return au
        }
        return makeDLSSynth()
    }

    static func program(_ au: AudioUnit, _ program: Int, channel: UInt8 = 0) {
        MusicDeviceMIDIEvent(au, UInt32(0xC0 | channel), UInt32(program & 0x7F), 0, 0)
    }
    static func noteOn(_ au: AudioUnit, pitch: Int, velocity: Int, channel: UInt8 = 0) {
        MusicDeviceMIDIEvent(au, UInt32(0x90 | channel), UInt32(pitch & 0x7F), UInt32(max(1, velocity) & 0x7F), 0)
    }
    static func noteOff(_ au: AudioUnit, pitch: Int, channel: UInt8 = 0) {
        MusicDeviceMIDIEvent(au, UInt32(0x80 | channel), UInt32(pitch & 0x7F), 0, 0)
    }
    static func allNotesOff(_ au: AudioUnit, channel: UInt8 = 0) {
        MusicDeviceMIDIEvent(au, UInt32(0xB0 | channel), 123, 0, 0)
    }

    /// A timed note on/off, in render sample frames, bound to a synth's AudioUnit.
    struct Event {
        var sample: AVAudioFramePosition
        var au: AudioUnit
        var isOn: Bool
        var pitch: Int
        var velocity: Int
        var channel: UInt8
    }

    /// Build sorted on/off events for a track's notes, offset by `from`.
    static func events(for notes: [MIDINote], au: AudioUnit, channel: UInt8 = 0,
                       from: TimeInterval, sampleRate: Double) -> [Event] {
        var events: [Event] = []
        for note in notes {
            let offT = note.start + note.duration - from
            guard offT > 0 else { continue }
            let onT = max(0, note.start - from)
            events.append(Event(sample: AVAudioFramePosition(onT * sampleRate), au: au,
                                isOn: true, pitch: note.pitch, velocity: note.velocity, channel: channel))
            events.append(Event(sample: AVAudioFramePosition(offT * sampleRate), au: au,
                                isOn: false, pitch: note.pitch, velocity: 0, channel: channel))
        }
        return events
    }
}

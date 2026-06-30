import Foundation
import CoreMIDI

/// Receives note on/off from any connected CoreMIDI source (a hardware/software controller).
/// Callbacks fire on a CoreMIDI thread — hop to the main actor in the handler.
final class MIDIInput {
    /// (isОn, pitch 0…127, velocity 0…127)
    var onNote: ((Bool, Int, Int) -> Void)?
    /// Called when the set of connected sources changes (true = at least one).
    var onSourcesChanged: ((Bool) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    init() {
        MIDIClientCreateWithBlock("Gosan" as CFString, &client) { [weak self] _ in
            self?.connectAllSources()
        }
        MIDIInputPortCreateWithBlock(client, "Gosan Input" as CFString, &port) { [weak self] packetList, _ in
            self?.handle(packetList)
        }
        connectAllSources()
    }

    var hasSources: Bool { MIDIGetNumberOfSources() > 0 }

    private func connectAllSources() {
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            MIDIPortConnectSource(port, MIDIGetSource(i), nil)
        }
        onSourcesChanged?(count > 0)
    }

    private func handle(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let length = Int(packet.length)
            withUnsafeBytes(of: packet.data) { raw in
                var i = 0
                while i < length {
                    let status = raw[i]
                    let command = status & 0xF0
                    switch command {
                    case 0x90, 0x80:
                        guard i + 2 < length else { i = length; break }
                        let pitch = Int(raw[i + 1]), velocity = Int(raw[i + 2])
                        if command == 0x90 && velocity > 0 { onNote?(true, pitch, velocity) }
                        else { onNote?(false, pitch, 0) }
                        i += 3
                    case 0xA0, 0xB0, 0xE0: i += 3   // poly-aftertouch / CC / pitch-bend
                    case 0xC0, 0xD0: i += 2          // program change / channel pressure
                    default: i += 1
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }
}

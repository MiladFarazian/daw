import AVFoundation
import AudioToolbox

/// Discovers and instantiates system Audio Unit effects to insert on a track.
enum PluginHost {
    struct AvailableAU: Identifiable, Hashable {
        var id: String { "\(type)-\(subType)-\(manufacturer)" }
        let name: String
        let manufacturerName: String
        let type: UInt32
        let subType: UInt32
        let manufacturer: UInt32
    }

    /// All installed effect / music-effect Audio Units, sorted by name.
    static func availableEffects() -> [AvailableAU] {
        let manager = AVAudioUnitComponentManager.shared()
        var result: [AvailableAU] = []
        for auType in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: auType, componentSubType: 0,
                                                 componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for comp in manager.components(matching: desc) {
                let cd = comp.audioComponentDescription
                result.append(AvailableAU(name: comp.name, manufacturerName: comp.manufacturerName,
                                          type: cd.componentType, subType: cd.componentSubType,
                                          manufacturer: cd.componentManufacturer))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func ref(for au: AvailableAU) -> PluginRef {
        PluginRef(name: au.name, type: au.type, subType: au.subType, manufacturer: au.manufacturer)
    }

    /// Synchronously instantiate an AVAudioUnit for a plugin reference (offline-safe).
    static func instantiate(_ ref: PluginRef) -> AVAudioUnit? {
        let cd = AudioComponentDescription(componentType: ref.type, componentSubType: ref.subType,
                                           componentManufacturer: ref.manufacturer,
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
}

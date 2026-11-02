import Foundation

enum AudioTransport: Equatable, Sendable {
    case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, virtual, aggregate, other
}

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    let id: UInt32
    var uid: String
    var name: String
    var transport: AudioTransport

    var symbol: String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods") { return "airpods" }
        return transport == .bluetooth ? "headphones" : "hifispeaker.fill"
    }

    /// Bluetooth audio UIDs start with the device address: `AA-BB-CC-DD-EE-FF:output`.
    /// This is what ties a battery reading to one specific device rather than to a name.
    var bluetoothAddress: String? {
        let prefix = uid.prefix(17)
        guard transport == .bluetooth, prefix.count == 17, prefix.filter({ $0 == "-" || $0 == ":" }).count == 5 else { return nil }
        return prefix.replacingOccurrences(of: "-", with: ":").uppercased()
    }
}

/// The default output as the driver reports it. Devices differ: HDMI and many USB interfaces have
/// no software volume at all, and then `volume` is nil rather than a guess.
struct OutputState: Equatable, Sendable {
    var device: AudioOutputDevice
    var volume: Float?
    var isMuted: Bool?
    var canSetVolume: Bool
    var canMute: Bool

    var percentage: Int? { volume.map { Int(($0 * 100).rounded()) } }
    var effectivelyMuted: Bool { isMuted == true }
}

enum OutputEvent: Equatable, Sendable {
    case levelChanged(OutputState)
    case deviceChanged(AudioOutputDevice)
}

/// Turns output snapshots into events. Which device is current changes the meaning of its volume,
/// so a device switch is never reported as a volume change.
struct OutputChangeDetector: Sendable {
    private var previous: OutputState?

    /// After sleep, values can move without anyone touching a key.
    mutating func resync() {
        previous = nil
    }

    mutating func process(_ state: OutputState?) -> [OutputEvent] {
        defer { previous = state }
        guard let state, let previous else { return [] }
        if state.device.id != previous.device.id {
            return [.deviceChanged(state.device)]
        }
        let levelMoved = state.percentage != previous.percentage
        let muteMoved = state.isMuted != previous.isMuted
        guard state.volume != nil, levelMoved || muteMoved else { return [] }
        return [.levelChanged(state)]
    }
}

enum DeviceConnectionEvent: Equatable, Sendable {
    case connected(AudioOutputDevice)
    case disconnected(AudioOutputDevice)
}

/// A Bluetooth output appears in Core Audio exactly while it's connected, which reports connection
/// without any Bluetooth permission.
struct BluetoothOutputTracker: Sendable {
    private var known: [String: AudioOutputDevice]?

    mutating func process(_ devices: [AudioOutputDevice]) -> [DeviceConnectionEvent] {
        let current = Dictionary(devices.filter { $0.transport == .bluetooth }.map { ($0.uid, $0) }) { first, _ in first }
        defer { known = current }
        guard let known else { return [] }
        let added = current.filter { known[$0.key] == nil }.values.sorted { $0.name < $1.name }
        let removed = known.filter { current[$0.key] == nil }.values.sorted { $0.name < $1.name }
        return removed.map(DeviceConnectionEvent.disconnected) + added.map(DeviceConnectionEvent.connected)
    }

    var connected: [AudioOutputDevice] {
        (known ?? [:]).values.sorted { $0.name < $1.name }
    }
}

import AudioToolbox
import CoreAudio
import Foundation

/// Access to system audio outputs. Implementations may block, so callers stay off the main thread.
protocol AudioOutputSystem: AnyObject, Sendable {
    func currentOutput() -> OutputState?
    func outputDevices() -> [AudioOutputDevice]
    /// Both return whether the driver accepted the write.
    @discardableResult func setVolume(_ volume: Float, device: UInt32) -> Bool
    @discardableResult func setMuted(_ muted: Bool, device: UInt32) -> Bool
    /// `onChange` fires on an arbitrary queue, several times for one change.
    func startObserving(onChange: @escaping @Sendable () -> Void)
    func stopObserving()
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type = T.self) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.move()
    }

    static func readString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func readArray(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func write<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: T) -> Bool {
        var address = address
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }
}

final class CoreAudioOutputSystem: AudioOutputSystem, @unchecked Sendable {
    private typealias Property = CoreAudioProperty

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let output = kAudioObjectPropertyScopeOutput
    private static let systemProperties = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]

    private let queue = DispatchQueue(label: "com.athene.morph.audio-output")
    /// All below are only touched on `queue`.
    private var onChange: (@Sendable () -> Void)?
    private var observedDevice: AudioObjectID?
    private var observedAddresses: [AudioObjectPropertyAddress] = []
    /// Removal matches on block identity, so one block is kept for the object's whole life.
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleChange()
    }

    // MARK: - Reading

    func currentOutput() -> OutputState? {
        guard let id = defaultOutputDevice(), let device = describe(id) else { return nil }
        let volumeAddress = volumeAddresses(for: id)
        let muteAddress = muteAddress(for: id)
        return OutputState(device: device, volume: readVolume(id, addresses: volumeAddress),
                           isMuted: muteAddress.flatMap { Property.read(id, $0, as: UInt32.self) }.map { $0 != 0 },
                           canSetVolume: !volumeAddress.isEmpty && volumeAddress.allSatisfy { Property.isSettable(id, $0) },
                           canMute: muteAddress.map { Property.isSettable(id, $0) } ?? false)
    }

    func outputDevices() -> [AudioOutputDevice] {
        Property.readArray(Self.system, Property.address(kAudioHardwarePropertyDevices))
            .filter(hasOutputStreams)
            .compactMap(describe)
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = Property.read(Self.system, Property.address(kAudioHardwarePropertyDefaultOutputDevice))
        return id == kAudioObjectUnknown ? nil : id
    }

    private func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        !Property.readArray(id, Property.address(kAudioDevicePropertyStreams, scope: Self.output)).isEmpty
    }

    private func describe(_ id: AudioObjectID) -> AudioOutputDevice? {
        guard let uid = Property.readString(id, Property.address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = Property.readString(id, Property.address(kAudioObjectPropertyName)) ?? "Audio Output"
        let transport: UInt32 = Property.read(id, Property.address(kAudioDevicePropertyTransportType)) ?? 0
        return AudioOutputDevice(id: id, uid: uid, name: name, transport: Self.transport(transport))
    }

    private static func transport(_ raw: UInt32) -> AudioTransport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate: .aggregate
        default: .other
        }
    }

    /// The first scheme a driver supports: the virtual main control, a main element, or per-channel.
    private func volumeAddresses(for id: AudioObjectID) -> [AudioObjectPropertyAddress] {
        var virtual = Property.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: Self.output)
        if AudioObjectHasProperty(id, &virtual) { return [virtual] }

        var main = Property.address(kAudioDevicePropertyVolumeScalar, scope: Self.output)
        if AudioObjectHasProperty(id, &main) { return [main] }

        let stereo: [UInt32]? = Property.read(id, Property.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: Self.output),
                                              as: (UInt32, UInt32).self).map { [$0.0, $0.1] }
        return (stereo ?? [1, 2]).compactMap { channel in
            var address = Property.address(kAudioDevicePropertyVolumeScalar, scope: Self.output, element: channel)
            return AudioObjectHasProperty(id, &address) ? address : nil
        }
    }

    private func muteAddress(for id: AudioObjectID) -> AudioObjectPropertyAddress? {
        var main = Property.address(kAudioDevicePropertyMute, scope: Self.output)
        if AudioObjectHasProperty(id, &main) { return main }
        var first = Property.address(kAudioDevicePropertyMute, scope: Self.output, element: 1)
        return AudioObjectHasProperty(id, &first) ? first : nil
    }

    private func readVolume(_ id: AudioObjectID, addresses: [AudioObjectPropertyAddress]) -> Float? {
        let values = addresses.compactMap { Property.read(id, $0, as: Float32.self) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    // MARK: - Writing

    @discardableResult
    func setVolume(_ volume: Float, device: UInt32) -> Bool {
        let value = min(max(volume, 0), 1)
        let addresses = volumeAddresses(for: device)
        return !addresses.isEmpty && addresses.map { Property.write(device, $0, value: value) }.allSatisfy { $0 }
    }

    @discardableResult
    func setMuted(_ muted: Bool, device: UInt32) -> Bool {
        guard let address = muteAddress(for: device) else { return false }
        return Property.write(device, address, value: UInt32(muted ? 1 : 0))
    }

    // MARK: - Observing

    func startObserving(onChange: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard self.onChange == nil else { return }
            self.onChange = onChange
            for selector in Self.systemProperties {
                var address = Property.address(selector)
                AudioObjectAddPropertyListenerBlock(Self.system, &address, queue, listener)
            }
            observeCurrentDevice()
        }
    }

    func stopObserving() {
        queue.sync { [self] in
            guard onChange != nil else { return }
            onChange = nil
            for selector in Self.systemProperties {
                var address = Property.address(selector)
                AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, listener)
            }
            removeDeviceListeners()
        }
    }

    private func handleChange() {
        observeCurrentDevice()
        onChange?()
    }

    /// Moves the device listeners when the default output changes.
    private func observeCurrentDevice() {
        let device = defaultOutputDevice()
        guard device != observedDevice else { return }
        removeDeviceListeners()
        guard let device else { return }

        observedDevice = device
        observedAddresses = volumeAddresses(for: device) + [muteAddress(for: device)].compactMap { $0 }
        for var address in observedAddresses {
            AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        }
    }

    private func removeDeviceListeners() {
        if let observedDevice {
            for var address in observedAddresses {
                AudioObjectRemovePropertyListenerBlock(observedDevice, &address, queue, listener)
            }
        }
        observedDevice = nil
        observedAddresses = []
    }
}

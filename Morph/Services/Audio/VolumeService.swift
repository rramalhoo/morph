import Foundation
import Observation

/// System output state. Follows Core Audio's listeners, with no polling.
@MainActor
@Observable
final class VolumeService {
    private static let refreshDebounce = Duration.milliseconds(25)

    private(set) var output: OutputState?
    private(set) var connectedBluetooth: [AudioOutputDevice] = []

    @ObservationIgnored var onOutputEvent: ((OutputEvent) -> Void)?
    @ObservationIgnored var onConnectionEvent: ((DeviceConnectionEvent) -> Void)?

    @ObservationIgnored private let system: any AudioOutputSystem
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let queue = DispatchQueue(label: "com.athene.morph.volume")
    @ObservationIgnored private var detector = OutputChangeDetector()
    @ObservationIgnored private var tracker = BluetoothOutputTracker()
    @ObservationIgnored private var refreshWork: (any ScheduledWork)?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var generation = 0

    init(system: any AudioOutputSystem, scheduler: any Scheduling) {
        self.system = system
        self.scheduler = scheduler
    }

    var isControllable: Bool { output?.canSetVolume == true && output?.volume != nil }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        system.startObserving { [weak self] in
            Task { @MainActor in self?.requestRefresh() }
        }
        requestRefresh()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        refreshWork?.cancel()
        refreshWork = nil
        let system = system
        queue.async { system.stopObserving() }
        detector.resync()
        output = nil
    }

    /// Values read after waking aren't changes anyone made.
    func resynchronize() {
        detector.resync()
        requestRefresh()
    }

    func requestRefresh() {
        guard isStarted else { return }
        refreshWork?.cancel()
        refreshWork = scheduler.schedule(after: Self.refreshDebounce) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        generation += 1
        let current = generation
        let system = system
        queue.async { [weak self] in
            let state = system.currentOutput()
            let devices = system.outputDevices()
            Task { @MainActor in
                guard let self, self.isStarted, current == self.generation else { return }
                self.apply(state, devices: devices)
            }
        }
    }

    func apply(_ state: OutputState?, devices: [AudioOutputDevice]) {
        if output != state { output = state }
        let connections = tracker.process(devices)
        let bluetooth = tracker.connected
        if connectedBluetooth != bluetooth { connectedBluetooth = bluetooth }
        connections.forEach { onConnectionEvent?($0) }
        detector.process(state).forEach { onOutputEvent?($0) }
    }

    func setVolume(_ volume: Float) {
        guard var state = output, state.canSetVolume else { return }
        let value = min(max(volume, 0), 1)
        state.volume = value
        output = state
        let (system, id) = (system, state.device.id)
        queue.async { system.setVolume(value, device: id) }
    }

    /// Returns false if the output has no software volume, so callers can fall back.
    @discardableResult
    func adjustVolume(byPercent delta: Int) -> Bool {
        guard isControllable, let volume = output?.volume else { return false }
        setVolume(volume + Float(delta) / 100)
        return true
    }

    func toggleMute() {
        guard var state = output, state.canMute else { return }
        let muted = !state.effectivelyMuted
        state.isMuted = muted
        output = state
        let (system, id) = (system, state.device.id)
        queue.async { system.setMuted(muted, device: id) }
    }
}

import Foundation
import Observation

/// Batteries of connected accessories. Nothing here polls Bluetooth: it re-reads what macOS already
/// knows, when a device connects or the panel opens, and otherwise at a slow pace only if the panel
/// is on screen or alerts were asked for.
@MainActor
@Observable
final class DeviceBatteryService {
    /// Opening and closing the panel shouldn't turn into reads.
    private static let minimumInterval = Duration.seconds(20)

    private(set) var peripherals: [PeripheralReading] = []

    var refreshInterval = Duration.seconds(300)
    var alertsEnabled = false { didSet { updateTicking() } }
    var lowThreshold = 20
    /// The Battery tab is showing.
    var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            if isVisible { refresh() }
            updateTicking()
        }
    }

    @ObservationIgnored var onLow: ((PeripheralReading) -> Void)?

    @ObservationIgnored private let reader: any PeripheralInventoryReading
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let queue = DispatchQueue(label: "com.athene.morph.device-battery", qos: .utility)
    @ObservationIgnored private var tracker = PeripheralAlertTracker()
    @ObservationIgnored private var tickWork: (any ScheduledWork)?
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var isStarted = false

    init(reader: any PeripheralInventoryReading, scheduler: any Scheduling) {
        self.reader = reader
        self.scheduler = scheduler
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refresh(force: true)
        updateTicking()
    }

    func stop() {
        isStarted = false
        tickWork?.cancel()
        tickWork = nil
    }

    /// `force` is for something having actually changed, such as a device connecting.
    func refresh(force: Bool = false) {
        guard isStarted else { return }
        if !force, let lastRead, lastRead.duration(to: scheduler.now) < Self.minimumInterval { return }
        lastRead = scheduler.now
        let reader = reader
        queue.async { [weak self] in
            let readings = reader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(readings) }
            }
        }
    }

    func apply(_ readings: [PeripheralReading]) {
        if peripherals != readings { peripherals = readings }
        guard alertsEnabled else { return }
        tracker.process(readings, threshold: lowThreshold).forEach { onLow?($0) }
    }

    private func updateTicking() {
        tickWork?.cancel()
        tickWork = nil
        guard isStarted, isVisible || alertsEnabled else { return }
        tickWork = scheduler.schedule(after: refreshInterval) { [weak self] in
            self?.refresh(force: true)
            self?.updateTicking()
        }
    }
}

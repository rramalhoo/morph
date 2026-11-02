import Foundation
import IOKit.ps
import Observation

protocol PowerSourceReading: Sendable {
    /// `nil` on Macs without an internal battery.
    func read() -> BatterySnapshot?
}

struct IOKitPowerSourceReader: PowerSourceReading {
    func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        let powerState = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else {
                continue
            }
            func minutes(_ key: String) -> Int? {
                (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
            }
            return BatterySnapshot(
                percentage: Int((Double(capacity) / Double(maximum) * 100).rounded()),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnExternalPower: powerState == kIOPSACPowerValue,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToEmpty: minutes(kIOPSTimeToEmptyKey),
                minutesToFull: minutes(kIOPSTimeToFullChargeKey)
            )
        }
        return nil
    }
}

/// Battery state, driven entirely by IOKit's power source notification. There is no polling.
@MainActor
@Observable
final class BatteryService {
    private(set) var snapshot: BatterySnapshot?
    @ObservationIgnored var onEvent: ((BatteryEvent) -> Void)?

    @ObservationIgnored private let reader: any PowerSourceReading
    @ObservationIgnored private var detector: BatteryTransitionDetector
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    init(reader: any PowerSourceReading = IOKitPowerSourceReader(), lowThreshold: Int = 20) {
        self.reader = reader
        detector = BatteryTransitionDetector(lowThreshold: lowThreshold)
    }

    var lowThreshold: Int {
        get { detector.lowThreshold }
        set { detector.lowThreshold = newValue }
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            // Added to the main run loop below, so this always arrives on the main thread.
            MainActor.assumeIsolated { service.refresh() }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        refresh()
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
    }

    func refresh() {
        let latest = reader.read()
        if snapshot != latest { snapshot = latest }
        guard let latest else { return }
        detector.process(latest).forEach { onEvent?($0) }
    }
}

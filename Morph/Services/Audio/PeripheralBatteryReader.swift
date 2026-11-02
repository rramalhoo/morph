import Foundation
import IOKit.ps

protocol PeripheralBatteryReading: Sendable {
    /// The battery of exactly this device, or nil if macOS doesn't expose it.
    func percentage(forDeviceNamed name: String) -> Int?
}

/// The only public route is `IOPowerSources`, where macOS may list an accessory. AirPods often aren't
/// listed, and no public API offers their proprietary battery data, so nil is a normal answer.
struct PowerSourcePeripheralReader: PeripheralBatteryReading {
    func percentage(forDeviceNamed name: String) -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return Self.match(descriptions, name: name)
    }

    /// An exact, unambiguous name match, or nothing: two devices must never share a reading.
    static func match(_ descriptions: [[String: Any]], name: String) -> Int? {
        let candidates = descriptions.filter {
            $0[kIOPSTypeKey] as? String != kIOPSInternalBatteryType && $0[kIOPSNameKey] as? String == name
        }
        guard candidates.count == 1, let source = candidates.first,
              let capacity = source[kIOPSCurrentCapacityKey] as? Int,
              let maximum = source[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        return Int((Double(capacity) / Double(maximum) * 100).rounded())
    }
}

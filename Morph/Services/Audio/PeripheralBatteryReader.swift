import Foundation
import IOKit
import IOKit.ps

protocol PeripheralBatteryReading: Sendable {
    /// The battery of exactly this device, or nil if macOS doesn't expose it.
    func percentage(forDeviceNamed name: String) -> Int?
}

/// Everything the system will say about batteries other than the Mac's.
protocol PeripheralInventoryReading: Sendable {
    func read() -> [PeripheralReading]
}

/// Bluetooth accessories, without any Bluetooth permission. `IOPowerSources` is the documented
/// route. Apple's own keyboards, mice and trackpads usually appear only in the IORegistry instead,
/// where the `BatteryPercent` property is long-standing but undocumented, so it's treated as a
/// bonus: a device without it, or a macOS that removes it, simply shows as connected.
struct SystemPeripheralInventory: PeripheralInventoryReading {
    private static let hidClass = "AppleDeviceManagementHIDEventService"

    func read() -> [PeripheralReading] {
        var readings = Self.merged(powerSources: powerSources(), registry: registry())
        readings.sort { $0.name < $1.name }
        return readings
    }

    /// A power source is the better reading, and each name appears once.
    static func merged(powerSources: [PeripheralReading], registry: [PeripheralReading]) -> [PeripheralReading] {
        let names = Set(powerSources.map(\.name))
        return powerSources + registry.filter { !names.contains($0.name) }
    }

    private func powerSources() -> [PeripheralReading] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return sources.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String != kIOPSInternalBatteryType,
                  let name = description[kIOPSNameKey] as? String else { return nil }
            var percentage: Int?
            if let capacity = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percentage = Int((Double(capacity) / Double(maximum) * 100).rounded())
            }
            return PeripheralReading(name: name, percentage: percentage, isCharging: description[kIOPSIsChargingKey] as? Bool)
        }
    }

    private func registry() -> [PeripheralReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(Self.hidClass), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var readings: [PeripheralReading] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let name = property("Product") as? String, let percentage = property("BatteryPercent") as? Int,
                  !readings.contains(where: { $0.name == name }) else { continue }
            readings.append(PeripheralReading(name: name, percentage: percentage.clamped(to: 0...100), isCharging: nil))
        }
        return readings
    }
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

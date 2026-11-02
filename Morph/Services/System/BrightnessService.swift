import AppKit
import IOKit.graphics

protocol BrightnessReading: Sendable {
    /// 0 to 1, or nil where no public API can read this display.
    func read() -> Float?
}

/// `IODisplayGetFloatParameter` is the public reading. Apple silicon has no `IODisplayConnect`
/// services, so this returns nil there, and the island shows direction without a percentage.
struct IOKitBrightnessReader: BrightnessReading {
    func read() -> Float? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var value: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == KERN_SUCCESS {
                return value
            }
        }
        return nil
    }
}

/// macOS has no public notification for brightness, so this listens for the brightness keys that
/// reach macOS. Changes from Control Center or automatic adjustment can't be seen, and aren't
/// guessed at. Keys that `LevelKeyService` handles never arrive here.
@MainActor
final class BrightnessService {
    /// Slightly after the key, so a real reading reflects the new level.
    private static let readDelay = Duration.milliseconds(120)

    var onChange: ((_ increased: Bool, _ percentage: Int?) -> Void)?

    /// Swapped for the private reading only while the user has opted into replacing the HUD.
    var reader: any BrightnessReading
    private let scheduler: any Scheduling
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var readWork: (any ScheduledWork)?

    init(reader: any BrightnessReading = IOKitBrightnessReader(), scheduler: any Scheduling) {
        self.reader = reader
        self.scheduler = scheduler
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            let (subtype, data1) = (event.subtype.rawValue, event.data1)
            MainActor.assumeIsolated { self?.handle(subtype: subtype, data1: data1) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handle(subtype: event.subtype.rawValue, data1: event.data1)
            return event
        }
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
        readWork?.cancel()
        readWork = nil
    }

    func handle(subtype: Int16, data1: Int) {
        guard let press = LevelKeyPress(subtype: subtype, data1: data1), press.isDown, press.key.isBrightness else { return }
        let increased = press.key == .brightnessUp
        readWork?.cancel()
        readWork = scheduler.schedule(after: Self.readDelay) { [weak self] in
            guard let self else { return }
            self.onChange?(increased, self.reader.read().map { Int(($0 * 100).rounded()) })
        }
    }
}

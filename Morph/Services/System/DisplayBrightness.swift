import CoreGraphics
import Darwin

/// Real control of a display's brightness.
protocol BrightnessControlling: Sendable {
    var isSupported: Bool { get }
    /// False where the key should stay with macOS, such as the pointer being on another display
    /// that macOS controls itself.
    func canControl(pointer: CGPoint) -> Bool
    func read() -> Float?
    func write(_ value: Float) -> Bool
}

/// macOS has no public brightness API on Apple silicon, so this is the private DisplayServices
/// framework. It's used only with Replace macOS Brightness HUD on, and only for the built-in panel.
/// Loaded at runtime: if a macOS update removes it, the option turns unavailable and the keys stay
/// with macOS. The sandbox needs the `com.apple.backlightd` exception in `Morph.entitlements`.
final class DisplayServicesBrightness: BrightnessControlling, BrightnessReading, @unchecked Sendable {
    private typealias Read = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Symbols: @unchecked Sendable {
        let read: Read
        let write: Write
        let canChange: CanChange

        init?() {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
                  let read = dlsym(handle, "DisplayServicesGetBrightness"),
                  let write = dlsym(handle, "DisplayServicesSetBrightness"),
                  let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness") else { return nil }
            self.read = unsafeBitCast(read, to: Read.self)
            self.write = unsafeBitCast(write, to: Write.self)
            self.canChange = unsafeBitCast(canChange, to: CanChange.self)
        }
    }

    /// Nothing is loaded until the first call.
    private static let symbols = Symbols()

    private var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    var isSupported: Bool {
        guard let symbols = Self.symbols, let display = builtInDisplay else { return false }
        return symbols.canChange(display)
    }

    func canControl(pointer: CGPoint) -> Bool {
        guard isSupported, let symbols = Self.symbols else { return false }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(pointer, 1, &display, &count) == .success, count > 0 else { return true }
        return CGDisplayIsBuiltin(display) != 0 || !symbols.canChange(display)
    }

    func read() -> Float? {
        guard let symbols = Self.symbols, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return symbols.read(display, &value) == 0 ? value : nil
    }

    func write(_ value: Float) -> Bool {
        guard let symbols = Self.symbols, let display = builtInDisplay else { return false }
        return symbols.write(display, value) == 0
    }
}

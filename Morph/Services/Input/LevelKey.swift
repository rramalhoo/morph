import Foundation

/// A volume or brightness key as `NX_SYSDEFINED` reports it. Raw values are the `NX_KEYTYPE_*` codes.
enum LevelKey: Int, Sendable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7

    var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
}

struct LevelKeyPress: Equatable, Sendable {
    private static let auxiliaryControlSubtype: Int16 = 8
    private static let stateDown = 0xA
    private static let stateUp = 0xB

    var key: LevelKey
    var isDown: Bool

    init(key: LevelKey, isDown: Bool = true) {
        self.key = key
        self.isDown = isDown
    }

    /// Nil for every other system event, which includes play/pause and keyboard backlight.
    init?(subtype: Int16, data1: Int) {
        guard subtype == Self.auxiliaryControlSubtype, let key = LevelKey(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return nil }
        let state = (data1 & 0xFF00) >> 8
        guard state == Self.stateDown || state == Self.stateUp else { return nil }
        self.init(key: key, isDown: state == Self.stateDown)
    }
}

/// macOS gives some key combinations their own meaning, and those stay with macOS.
struct LevelKeyModifiers: Equatable, Sendable {
    var shift = false
    var option = false
    var commandOrControl = false

    static let none = LevelKeyModifiers()

    /// Shift and Option together means fine steps.
    var isFine: Bool { shift && option }
    /// Option alone opens the Sound or Displays settings.
    var belongsToSystem: Bool { commandOrControl || (option && !shift) }
}

/// Which keys Morph should handle. Off means macOS gets every event untouched.
struct LevelKeyPolicy: Equatable, Sendable {
    var volume = false
    var brightness = false
    var volumeStep = VolumeStep.five
    var brightnessStep = VolumeStep.five

    static let off = LevelKeyPolicy()

    var isOff: Bool { !volume && !brightness }
}

/// What a handled key changed.
enum LevelUpdate: Equatable, Sendable {
    case volume(percentage: Int, muted: Bool)
    case brightness(percentage: Int, increased: Bool)
}

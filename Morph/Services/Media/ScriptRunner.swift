import Foundation

/// Sendable mirror of the Apple Event descriptors the player scripts return.
enum ScriptValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case data(Data)
    case list([ScriptValue])
    case none

    var text: String? {
        if case .text(let value) = self { value } else { nil }
    }

    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var data: Data? {
        if case .data(let value) = self { value } else { nil }
    }

    var list: [ScriptValue]? {
        if case .list(let value) = self { value } else { nil }
    }
}

protocol ScriptRunning: Sendable {
    func run(_ source: String) async throws -> ScriptValue
}

/// Runs AppleScript on one private serial queue. `NSAppleScript` isn't safe for concurrent use and
/// a slow player must not stall the UI. Each script carries its own `with timeout`.
final class OSAScriptRunner: ScriptRunning, @unchecked Sendable {
    private static let compiledCacheLimit = 16

    private let queue = DispatchQueue(label: "com.athene.morph.applescript", qos: .userInitiated)
    /// Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String) async throws -> ScriptValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScriptValue, any Error>) in
            queue.async { [self] in
                autoreleasepool {
                    continuation.resume(with: Result { try execute(source) })
                }
            }
        }
    }

    private func execute(_ source: String) throws -> ScriptValue {
        var failure: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { throw MediaError.malformedResponse }
            guard created.compileAndReturnError(&failure) else { throw Self.error(from: failure) }
            if compiled.count >= Self.compiledCacheLimit { compiled.removeAll() }
            compiled[source] = created
            script = created
        }
        let descriptor = script.executeAndReturnError(&failure)
        if let failure { throw Self.error(from: failure) }
        return Self.value(from: descriptor)
    }

    private static func error(from dictionary: NSDictionary?) -> MediaError {
        let code = dictionary?[NSAppleScript.errorNumber] as? Int ?? 0
        let message = dictionary?[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        return mediaError(code: code, message: message)
    }

    static func mediaError(code: Int, message: String) -> MediaError {
        switch code {
        case -1743: .notAuthorized
        case -600, -609, -903: .notRunning
        case -1712: .timedOut
        default: .scriptFailed(code: code, message: message)
        }
    }

    private static func value(from descriptor: NSAppleEventDescriptor) -> ScriptValue {
        switch descriptor.descriptorType {
        case fourCharCode("list"):
            guard descriptor.numberOfItems > 0 else { return .list([]) }
            return .list((1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }.map(value(from:)))
        case fourCharCode("utxt"), fourCharCode("utf8"), fourCharCode("TEXT"):
            return .text(descriptor.stringValue ?? "")
        case fourCharCode("long"), fourCharCode("shor"), fourCharCode("doub"), fourCharCode("sing"), fourCharCode("comp"):
            return .number(descriptor.doubleValue)
        case fourCharCode("null"), fourCharCode("msng"):
            return .none
        default:
            return descriptor.data.isEmpty ? .none : .data(descriptor.data)
        }
    }

    private static func fourCharCode(_ code: StaticString) -> DescType {
        code.withUTF8Buffer { $0.reduce(0) { $0 << 8 | DescType($1) } }
    }
}

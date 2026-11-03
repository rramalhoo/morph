import AudioToolbox
import CoreAudio
import Foundation
import os

enum AudioCaptureError: Error, Equatable {
    case unsupportedSystem
    case noPlayerProcess
    case hardware(OSStatus)

    /// Whether trying again could help. A player can take a moment to appear in Core Audio.
    var isRetryable: Bool { self != .unsupportedSystem }

    var summary: String {
        switch self {
        case .unsupportedSystem: "Needs macOS 14.2 or later"
        case .noPlayerProcess: "The player has no audio process yet"
        case .hardware(let status): "Core Audio error \(status)"
        }
    }
}

/// What the capture can say about itself. Buffers arriving is what separates a quiet song from a
/// capture that has actually stopped.
struct AudioCaptureHealth: Equatable, Sendable {
    var bufferCount: UInt64
    /// The tap still follows the player's current processes.
    var followsPlayer: Bool
}

/// Captures one player's output so it can be measured. Audio is read in memory and discarded;
/// nothing is recorded, and the sound the user hears isn't touched (`muteBehavior = .unmuted`).
protocol AudioCapturing: AnyObject, Sendable {
    func start(bundleIdentifier: String, outputUID: String, sensitivity: Float,
               onLevels: @escaping @Sendable ([Float], Bool) -> Void,
               completion: @escaping @Sendable (AudioCaptureError?) -> Void)
    func setSensitivity(_ sensitivity: Float)
    func stop()
    /// Answers off the main thread, because reading the process list can block.
    func checkHealth(_ reply: @escaping @Sendable (AudioCaptureHealth) -> Void)
}

final class ProcessTapCapture: AudioCapturing, @unchecked Sendable {
    /// Setup and teardown can block for a moment, so never the main thread.
    private let control = DispatchQueue(label: "com.athene.morph.audio-capture", qos: .userInitiated)
    /// Buffers and FFT work. Separate from `control` because `AudioDeviceStop` waits for the IO
    /// block to return, and on one shared serial queue that wait would never end.
    private let analysis = DispatchQueue(label: "com.athene.morph.audio-analysis", qos: .userInitiated)
    /// Only touched on `control`.
    private var session: AnyObject?
    private var target: (bundleIdentifier: String, processes: Set<AudioObjectID>)?

    func start(bundleIdentifier: String, outputUID: String, sensitivity: Float,
               onLevels: @escaping @Sendable ([Float], Bool) -> Void,
               completion: @escaping @Sendable (AudioCaptureError?) -> Void) {
        control.async { [self] in
            guard #available(macOS 14.2, *) else {
                completion(.unsupportedSystem)
                return
            }
            closeSession()
            do {
                let processes = Self.playerProcesses(bundleIdentifier)
                guard !processes.isEmpty else { throw AudioCaptureError.noPlayerProcess }
                session = try TapSession(processes: processes, outputUID: outputUID, sensitivity: sensitivity,
                                         queue: analysis, onLevels: onLevels)
                target = (bundleIdentifier, Set(processes))
                completion(nil)
            } catch {
                completion(error as? AudioCaptureError ?? .hardware(-1))
            }
        }
    }

    func setSensitivity(_ sensitivity: Float) {
        control.async { [self] in
            guard #available(macOS 14.2, *), let tap = session as? TapSession else { return }
            analysis.async { tap.pipeline.setSensitivity(sensitivity) }
        }
    }

    func stop() {
        control.async { [self] in closeSession() }
    }

    func checkHealth(_ reply: @escaping @Sendable (AudioCaptureHealth) -> Void) {
        control.async { [self] in
            guard #available(macOS 14.2, *), let tap = session as? TapSession, let target else {
                reply(AudioCaptureHealth(bufferCount: 0, followsPlayer: true))
                return
            }
            let current = Set(Self.playerProcesses(target.bundleIdentifier))
            reply(AudioCaptureHealth(bufferCount: tap.bufferCount, followsPlayer: current.isEmpty || current == target.processes))
        }
    }

    private func closeSession() {
        guard #available(macOS 14.2, *) else { return }
        (session as? TapSession)?.close()
        session = nil
        target = nil
    }

    /// Players can render audio in helper processes, which share the bundle ID prefix.
    private static func playerProcesses(_ bundleIdentifier: String) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let list = CoreAudioProperty.readArray(system, CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList))
        return list.filter { process in
            CoreAudioProperty.readString(process, CoreAudioProperty.address(kAudioProcessPropertyBundleID))?
                .hasPrefix(bundleIdentifier) == true
        }
    }
}

@available(macOS 14.2, *)
private final class TapSession: @unchecked Sendable {
    let pipeline: WaveformPipeline
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let buffers = OSAllocatedUnfairLock(initialState: UInt64(0))

    var bufferCount: UInt64 { buffers.withLock { $0 } }

    init(processes: [AudioObjectID], outputUID: String, sensitivity: Float, queue: DispatchQueue,
         onLevels: @escaping @Sendable ([Float], Bool) -> Void) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Morph Waveform"

        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AudioCaptureError.hardware(status) }

        // Everything below must unwind the tap on failure.
        var succeeded = false
        var sampleRate = 48_000.0
        if let format: AudioStreamBasicDescription = CoreAudioProperty.read(tap, CoreAudioProperty.address(kAudioTapPropertyFormat)) {
            sampleRate = format.mSampleRate
        }
        pipeline = WaveformPipeline(sampleRate: sampleRate, sensitivity: sensitivity, onLevels: onLevels)
        defer { if !succeeded { close() } }

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Morph Waveform",
            kAudioAggregateDeviceUIDKey: "com.athene.morph.waveform.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate)
        guard status == noErr else { throw AudioCaptureError.hardware(status) }

        let (pipeline, buffers) = (pipeline, buffers)
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, input, _, _, _ in
            buffers.withLock { $0 &+= 1 }
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                pipeline.consume(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count),
                                 channels: Int(buffer.mNumberChannels))
                break
            }
        }
        guard status == noErr else { throw AudioCaptureError.hardware(status) }

        // The system shows the permission prompt, with NSAudioCaptureUsageDescription, at this call.
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { throw AudioCaptureError.hardware(status) }
        succeeded = true
    }

    func close() {
        if aggregate != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        procID = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}

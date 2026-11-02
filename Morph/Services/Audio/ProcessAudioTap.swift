import AudioToolbox
import CoreAudio
import Foundation

enum AudioCaptureError: Error, Equatable {
    case unsupportedSystem
    case noPlayerProcess
    case hardware(OSStatus)
}

/// Captures one player's output so it can be measured. Audio is read in memory and discarded;
/// nothing is recorded, and the sound the user hears isn't touched (`muteBehavior = .unmuted`).
protocol AudioCapturing: AnyObject, Sendable {
    func start(bundleIdentifier: String, outputUID: String, sensitivity: Float,
               onLevels: @escaping @Sendable ([Float], Bool) -> Void,
               completion: @escaping @Sendable (AudioCaptureError?) -> Void)
    func setSensitivity(_ sensitivity: Float)
    func stop()
}

final class ProcessTapCapture: AudioCapturing, @unchecked Sendable {
    /// Setup and teardown can take a moment, and FFT work runs here too. Never the main thread.
    private let queue = DispatchQueue(label: "com.athene.morph.audio-capture", qos: .userInitiated)
    /// Only touched on `queue`.
    private var session: AnyObject?

    func start(bundleIdentifier: String, outputUID: String, sensitivity: Float,
               onLevels: @escaping @Sendable ([Float], Bool) -> Void,
               completion: @escaping @Sendable (AudioCaptureError?) -> Void) {
        queue.async { [self] in
            guard #available(macOS 14.2, *) else {
                completion(.unsupportedSystem)
                return
            }
            (session as? TapSession)?.close()
            session = nil
            do {
                let processes = Self.playerProcesses(bundleIdentifier)
                guard !processes.isEmpty else { throw AudioCaptureError.noPlayerProcess }
                session = try TapSession(processes: processes, outputUID: outputUID, sensitivity: sensitivity,
                                         queue: queue, onLevels: onLevels)
                completion(nil)
            } catch {
                completion(error as? AudioCaptureError ?? .hardware(-1))
            }
        }
    }

    func setSensitivity(_ sensitivity: Float) {
        queue.async { [self] in
            guard #available(macOS 14.2, *) else { return }
            (session as? TapSession)?.pipeline.setSensitivity(sensitivity)
        }
    }

    func stop() {
        queue.async { [self] in
            guard #available(macOS 14.2, *) else { return }
            (session as? TapSession)?.close()
            session = nil
        }
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
private final class TapSession {
    let pipeline: WaveformPipeline
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

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

        let pipeline = pipeline
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, input, _, _, _ in
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

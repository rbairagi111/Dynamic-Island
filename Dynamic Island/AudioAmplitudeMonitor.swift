import Combine
import CoreAudio
import CoreAudioTypes
import Foundation

enum AudioAmplitudeDSP {
    /// RMS of float samples. Empty input is 0.
    static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
    }

    /// Mix loudness and transients without clipping the top of the range.
    /// Linear `max(rms * 3.2, …)` pins compressed songs at 1.0; this curve
    /// keeps a medium body so hats / beats can still expand the bars.
    static func drive(rms: Float, highFrequency: Float) -> Float {
        let body = compress(rms, gain: 4.0)
        let hit = compress(highFrequency, gain: 9.5)
        return min(1, body * 0.58 + hit * 0.62)
    }

    static func compress(_ value: Float, gain: Float) -> Float {
        1 - exp(-max(0, value) * gain)
    }

    static func highFrequencyRMS(samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var sum: Float = 0
        for i in 1..<samples.count {
            let d = samples[i] - samples[i - 1]
            sum += d * d
        }
        return sqrt(sum / Float(samples.count - 1))
    }

    static func smooth(current: Float, target: Float) -> Float {
        let coeff: Float = target > current ? 0.58 : 0.28
        return current + (target - current) * coeff
    }
}

/// Live RMS of system output via Core Audio process tap (macOS 14.2+).
/// One permission: System Audio Recording (`NSAudioCaptureUsageDescription`).
/// Denial / tap failure: `amplitude` stays 0 and `isRunning` is false (waveform falls back).
final class AudioAmplitudeMonitor: ObservableObject {
    static let shared = AudioAmplitudeMonitor()

    /// Normalized, smoothed RMS in `0...1`.
    @Published private(set) var amplitude: CGFloat = 0
    @Published private(set) var isRunning = false

    private let runtime = TapRuntime()
    private var didFailThisEnablement = false
    private var startRequested = false

    static var isSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion > 14 { return true }
        if version.majorVersion == 14 && version.minorVersion >= 2 { return true }
        return false
    }

    func start() {
        // Disabled: a Core Audio process tap shows the System Audio Recording
        // sheet on every unsigned/debug launch. Waveform stays simulated.
    }

    func stop() {
        startRequested = false
        runtime.stop()
        isRunning = false
        amplitude = 0
    }

    func resetFailure() {
        didFailThisEnablement = false
    }

    deinit {
        runtime.stop()
    }
}

/// HAL handles. `@unchecked Sendable` so the IO block can run off MainActor.
private nonisolated final class TapRuntime: @unchecked Sendable {
    private enum TapError: LocalizedError {
        case unsupported
        case tapCreation(OSStatus)
        case aggregate(OSStatus)
        case ioProc(OSStatus)
        case deviceStart(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "macOS 14.2 or later required"
            case .tapCreation(let s): return "AudioHardwareCreateProcessTap (\(s))"
            case .aggregate(let s): return "AudioHardwareCreateAggregateDevice (\(s))"
            case .ioProc(let s): return "AudioDeviceCreateIOProcIDWithBlock (\(s))"
            case .deviceStart(let s): return "AudioDeviceStart (\(s))"
            }
        }
    }

    private let queue = DispatchQueue(label: "island.audio-amplitude", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var onAmplitude: ((Float) -> Void)?
    private var smoothed: Float = 0
    private var lastEmit: CFAbsoluteTime = 0
    private var isRunning = false

    func start(
        onAmplitude: @escaping (Float) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        if #available(macOS 14.2, *) {
            queue.async {
                if self.isRunning {
                    self.onAmplitude = onAmplitude
                    completion(nil)
                    return
                }
                self.onAmplitude = onAmplitude
                do {
                    try self.startLocked()
                    self.isRunning = true
                    completion(nil)
                } catch {
                    self.teardownLocked()
                    completion(error)
                }
            }
        } else {
            completion(TapError.unsupported)
        }
    }

    func stop() {
        queue.sync {
            guard isRunning else { return }
            teardownLocked()
            isRunning = false
            onAmplitude = nil
            smoothed = 0
            lastEmit = 0
        }
    }

    @available(macOS 14.2, *)
    private func startLocked() throws {
        let excluded = Self.currentProcessObjectIDs()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Dynamic Island amplitude"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if let uid = Self.defaultOutputUID() {
            description.deviceUID = uid
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { throw TapError.tapCreation(tapStatus) }
        tapID = newTapID

        try createAggregate(tapUUID: description.uuid)
        Self.waitUntilAlive(aggregateID)
        try installIOProc()
    }

    @available(macOS 14.2, *)
    private func createAggregate(tapUUID: UUID) throws {
        // Tap-only private aggregate: do not also list the output as a subdevice
        // (USB interfaces often then never fire the IO proc).
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dynamic Island Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var newID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID)
        guard status == noErr else { throw TapError.aggregate(status) }
        aggregateID = newID
    }

    private func installIOProc() throws {
        let device = aggregateID
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self]
            _, inInputData, _, _, _ in
            self?.ingest(inInputData)
        }
        guard status == noErr, procID != nil else { throw TapError.ioProc(status) }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else { throw TapError.deviceStart(status) }
    }

    private func ingest(_ bufferList: UnsafePointer<AudioBufferList>) {
        let metrics = Self.bufferMetrics(bufferList)
        let target = AudioAmplitudeDSP.drive(rms: metrics.rms, highFrequency: metrics.hf)
        smoothed = AudioAmplitudeDSP.smooth(current: smoothed, target: target)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmit >= (1.0 / 45.0) else { return }
        lastEmit = now
        onAmplitude?(smoothed)
    }

    private static func rms(_ bufferList: UnsafePointer<AudioBufferList>) -> Float {
        bufferMetrics(bufferList).rms
    }

    private static func bufferMetrics(_ bufferList: UnsafePointer<AudioBufferList>) -> (rms: Float, hf: Float) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        var sum: Float = 0
        var hfSum: Float = 0
        var count = 0
        var hfCount = 0
        var previous: Float = 0
        var hasPrevious = false
        for buffer in abl {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = data.assumingMemoryBound(to: Float.self)
            for i in 0..<samples {
                let s = ptr[i]
                sum += s * s
                if hasPrevious {
                    let d = s - previous
                    hfSum += d * d
                    hfCount += 1
                }
                previous = s
                hasPrevious = true
            }
            count += samples
        }
        let rms = count > 0 ? sqrt(sum / Float(count)) : 0
        let hf = hfCount > 0 ? sqrt(hfSum / Float(hfCount)) : 0
        return (rms, hf)
    }

    private static func waitUntilAlive(_ deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<20 {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
            if status == noErr, alive != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var cfUID: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
        guard status == noErr, let cfUID else { return nil }
        return cfUID.takeRetainedValue() as String
    }

    private static func currentProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &dataSize,
            &processObjectID
        )
        guard status == noErr, processObjectID != kAudioObjectUnknown else { return [] }
        return [processObjectID]
    }

    private func teardownLocked() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

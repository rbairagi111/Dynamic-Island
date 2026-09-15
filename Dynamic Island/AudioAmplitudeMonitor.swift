import Accelerate
import Combine
import CoreAudio
import CoreAudioTypes
import Foundation

enum AudioAmplitudeDSP {
    static let bandCount = 7

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

    /// Log-spaced spectrum energies (`bandCount` bars, low→high), each
    /// auto-gained so quiet treble can hit full height like a YouTube EQ —
    /// without AGC, bass alone draws a left→right staircase.
    static func spectrumBands(samples: [Float], bandCount: Int = bandCount) -> [Float] {
        SpectrumFFT.shared.bands(samples: samples, bandCount: bandCount)
    }
}

/// Reusable 512-point real FFT for the audio tap thread.
private final class SpectrumFFT: @unchecked Sendable {
    static let shared = SpectrumFFT()

    private let log2n: vDSP_Length = 9
    private let n = 512
    private let setup: FFTSetup
    private var window: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    /// Per-band peak for AGC (decays slowly so each bar can still punch).
    private var peaks: [Float]
    private var smoothed: [Float]
    /// Assumed tap rate; process taps are almost always 48k / 44.1k.
    private let sampleRate: Float = 48_000

    private init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
        peaks = [Float](repeating: 0.08, count: AudioAmplitudeDSP.bandCount)
        smoothed = [Float](repeating: 0, count: AudioAmplitudeDSP.bandCount)
        for i in 0..<n {
            window[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n - 1))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func bands(samples: [Float], bandCount: Int) -> [Float] {
        guard samples.count >= 64, bandCount > 0 else {
            return Array(repeating: 0, count: max(bandCount, 0))
        }

        var input = [Float](repeating: 0, count: n)
        let take = min(n, samples.count)
        let offset = samples.count - take
        for i in 0..<take {
            input[i] = samples[offset + i] * window[i]
        }

        for i in 0..<(n / 2) {
            realp[i] = input[i * 2]
            imagp[i] = input[i * 2 + 1]
        }
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        realp[0] = 0
        imagp[0] = 0
        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))

        var scale: Float = 1.0 / Float(n)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(n / 2))
        var count = Int32(n / 2)
        vvsqrtf(&magnitudes, magnitudes, &count)

        // Fixed musical edges (Hz) so highs get real bins, not leftover scraps.
        let edges = bandEdgesHz(bandCount: bandCount)
        let hzPerBin = sampleRate / Float(n)
        var raw = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let startBin = max(1, Int(edges[b] / hzPerBin))
            let endBin = max(startBin + 1, Int(edges[b + 1] / hzPerBin))
            var sum: Float = 0
            let lo = min(startBin, n / 2 - 1)
            let hi = min(endBin, n / 2)
            for k in lo..<hi {
                sum += magnitudes[k]
            }
            raw[b] = sum / Float(max(1, hi - lo))
        }

        if peaks.count != bandCount {
            peaks = Array(repeating: 0.08, count: bandCount)
            smoothed = Array(repeating: 0, count: bandCount)
        }

        var out = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            // Peak decays moderately so AGC still opens for quiet bands
            // without flickering every FFT hop.
            peaks[i] = max(raw[i], peaks[i] * 0.985)
            let denom = max(peaks[i], 0.02)
            var normalized = min(1.15, raw[i] / denom)
            // Mild squash — keep body, avoid hash/radio sparkle.
            normalized = pow(max(0, normalized), 1.25)
            let driven = AudioAmplitudeDSP.compress(normalized, gain: 2.6)
            // Smooth attack + smooth release (not radio-static flicker).
            let coeff: Float = driven > smoothed[i] ? 0.42 : 0.28
            smoothed[i] += (driven - smoothed[i]) * coeff
            if smoothed[i] < 0.07 {
                smoothed[i] *= 0.88
            }
            out[i] = min(1, max(0, smoothed[i]))
        }

        // Soft neighbor blend for organic shape without holding bars up.
        var scattered = out
        for i in 0..<bandCount {
            let left = out[(i + bandCount - 1) % bandCount]
            let right = out[(i + 1) % bandCount]
            scattered[i] = min(1, out[i] * 0.72 + left * 0.14 + right * 0.14)
            if scattered[i] < 0.05 {
                scattered[i] = 0
            }
        }
        return scattered
    }

    /// Low → high edges for `bandCount` bands (last value is Nyquist).
    private func bandEdgesHz(bandCount: Int) -> [Float] {
        // Musical visualizer ranges — more resolution in mid/high than raw log(bin).
        let template: [Float] = [40, 80, 160, 320, 640, 1400, 3200, 7000, 16_000]
        if bandCount + 1 == template.count { return template }
        var edges = [Float](repeating: 0, count: bandCount + 1)
        let nyquist = sampleRate * 0.5
        edges[0] = 40
        edges[bandCount] = min(nyquist, 18_000)
        for i in 1..<bandCount {
            let t = Float(i) / Float(bandCount)
            edges[i] = edges[0] * pow(edges[bandCount] / edges[0], t)
        }
        return edges
    }
}

/// Live spectrum of system output via Core Audio process tap (macOS 14.2+).
/// One permission: System Audio Recording (`NSAudioCaptureUsageDescription`).
/// Denial / tap failure: bands stay 0 and `isRunning` is false (waveform falls back).
final class AudioAmplitudeMonitor: ObservableObject {
    static let shared = AudioAmplitudeMonitor()

    /// Normalized, smoothed RMS in `0...1` (overall loudness).
    @Published private(set) var amplitude: CGFloat = 0
    /// Per-bar spectrum energies low→high (`AudioAmplitudeDSP.bandCount`).
    @Published private(set) var bands: [CGFloat] = Array(
        repeating: 0,
        count: AudioAmplitudeDSP.bandCount
    )
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
        guard Self.isSupported else { return }
        guard !startRequested else { return }
        guard !didFailThisEnablement else { return }
        startRequested = true
        runtime.start(
            onSpectrum: { [weak self] spectrum, drive in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.amplitude = CGFloat(min(1, max(0, drive)))
                    if spectrum.count == AudioAmplitudeDSP.bandCount {
                        self.bands = spectrum.map { CGFloat(min(1, max(0, $0))) }
                    }
                }
            },
            completion: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        NSLog("[AudioAmplitude] tap failed: %@", error.localizedDescription)
                        self.didFailThisEnablement = true
                        self.startRequested = false
                        self.isRunning = false
                        self.amplitude = 0
                        self.bands = Array(repeating: 0, count: AudioAmplitudeDSP.bandCount)
                        return
                    }
                    self.isRunning = true
                }
            }
        )
    }

    func stop() {
        startRequested = false
        runtime.stop()
        isRunning = false
        amplitude = 0
        bands = Array(repeating: 0, count: AudioAmplitudeDSP.bandCount)
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
    private var onSpectrum: (([Float], Float) -> Void)?
    private var smoothedDrive: Float = 0
    private var lastEmit: CFAbsoluteTime = 0
    private var isRunning = false

    func start(
        onSpectrum: @escaping ([Float], Float) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        if #available(macOS 14.2, *) {
            queue.async {
                if self.isRunning {
                    self.onSpectrum = onSpectrum
                    completion(nil)
                    return
                }
                self.onSpectrum = onSpectrum
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
            onSpectrum = nil
            smoothedDrive = 0
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
        let samples = Self.monoSamples(bufferList)
        guard !samples.isEmpty else { return }
        let metrics = Self.metrics(samples: samples)
        let drive = AudioAmplitudeDSP.drive(rms: metrics.rms, highFrequency: metrics.hf)
        smoothedDrive = AudioAmplitudeDSP.smooth(current: smoothedDrive, target: drive)
        let bands = AudioAmplitudeDSP.spectrumBands(
            samples: samples,
            bandCount: AudioAmplitudeDSP.bandCount
        )

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmit >= (1.0 / 30.0) else { return }
        lastEmit = now
        onSpectrum?(bands, smoothedDrive)
    }

    private static func monoSamples(_ bufferList: UnsafePointer<AudioBufferList>) -> [Float] {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        var out: [Float] = []
        for buffer in abl {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = data.assumingMemoryBound(to: Float.self)
            // Prefer a mono mix of interleaved stereo.
            if buffer.mNumberChannels == 2, count >= 2 {
                let frames = count / 2
                out.reserveCapacity(out.count + frames)
                for f in 0..<frames {
                    out.append(0.5 * (ptr[f * 2] + ptr[f * 2 + 1]))
                }
            } else {
                out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
            }
        }
        return out
    }

    private static func metrics(samples: [Float]) -> (rms: Float, hf: Float) {
        let rms = AudioAmplitudeDSP.rms(samples: samples)
        let hf = AudioAmplitudeDSP.highFrequencyRMS(samples: samples)
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

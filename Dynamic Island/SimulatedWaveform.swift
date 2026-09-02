import Foundation
import Combine

/// Alcove-style fake equalizer: irregular motion and occasional hits, not a looping sine.
/// Not tied to the real mix — no audio tap.
struct SimulatedWaveformEngine {
    static let barCount = 7
    static let idleLevel: CGFloat = 0.2

    private(set) var levels: [CGFloat]
    private var time: TimeInterval = 0
    private var nextPulseAt: TimeInterval = 0.08
    private var pulse: CGFloat = 0
    private var hat: CGFloat = 0
    private var leadA = 1
    private var leadB = 4
    private var wasPlaying = false
    private var rng: SplitMix64
    private var live = LiveWaveformMapper()

    init(seed: UInt64 = 0xC0FFEE) {
        levels = Array(repeating: Self.idleLevel, count: Self.barCount)
        rng = SplitMix64(state: seed == 0 ? 1 : seed)
    }

    /// Advance one frame. `dt` is seconds (e.g. 1/30).
    /// Pass `liveAmplitude` when the shared CATap RMS feed is running.
    mutating func tick(
        dt: TimeInterval,
        playing: Bool,
        liveAmplitude: CGFloat? = nil
    ) -> [CGFloat] {
        let step = max(dt, 1.0 / 120.0)
        time += step

        if playing, let liveAmplitude {
            levels = live.tick(dt: step, amplitude: liveAmplitude)
            return levels
        }

        if playing && !wasPlaying {
            pickLeads()
            pulse = 0.95
            hat = 0.55
            nextPulseAt = time + rng.next(in: 0.28...0.72)
        }
        wasPlaying = playing

        guard playing else {
            for i in 0..<Self.barCount {
                levels[i] += (Self.idleLevel - levels[i]) * min(1, CGFloat(step) * 3.6)
            }
            Self.mirror(&levels)
            pulse = 0
            hat = 0
            return levels
        }

        if time >= nextPulseAt {
            pickLeads()
            pulse = CGFloat(rng.next(in: 0.82...1.0))
            hat = CGFloat(rng.next(in: 0.35...0.85))
            nextPulseAt = time + rng.next(in: 0.22...0.78)
        }

        pulse *= CGFloat(exp(-step * 3.2))
        hat *= CGFloat(exp(-step * 6.4))

        for i in 0..<Self.barCount {
            let bass = 1 - CGFloat(i) / CGFloat(Self.barCount - 1)
            let treble = CGFloat(i) / CGFloat(Self.barCount - 1)
            let isLead = i == leadA || i == leadB

            // Incommensurate oscillators so the pattern does not close on a short loop.
            let t = time
            let iD = Double(i)
            let wander =
                0.50 * (0.5 + 0.5 * sin(t * (0.19 + iD * 0.031) + iD * 1.7))
                + 0.28 * (0.5 + 0.5 * sin(t * (1.13 + iD * 0.47) + iD * 0.9))
                + 0.22 * (0.5 + 0.5 * sin(t * (2.61 + iD * 0.21) + iD * 2.3))

            // Quiet floor on most bars; two leads punch to full height.
            var energy = 0.08 + 0.36 * CGFloat(wander)
            energy += pulse * (0.06 + 0.22 * bass)
            energy += isLead ? pulse * 0.72 : 0
            energy += hat * (isLead ? 0.28 * treble : 0.06 * treble)
            energy = min(1, max(0.08, energy))

            let rate: CGFloat = energy > levels[i] ? 18 : 5.0
            levels[i] += (energy - levels[i]) * min(1, CGFloat(step) * rate)
        }
        Self.mirror(&levels)

        return levels
    }

    /// Copy the left half onto the right so outer bars always match.
    static func mirror(_ levels: inout [CGFloat]) {
        let n = levels.count
        guard n > 1 else { return }
        for i in 0..<(n / 2) {
            levels[n - 1 - i] = levels[i]
        }
    }

    private mutating func pickLeads() {
        leadA = Int(rng.next(in: 0...2.999))
        leadB = min(2, leadA + 1)
    }
}

/// Drives `SimulatedWaveformEngine` on the main run loop while media is playing.
final class SimulatedWaveform: ObservableObject {
    static let barCount = SimulatedWaveformEngine.barCount

    @Published private(set) var levels: [CGFloat]

    private var engine: SimulatedWaveformEngine
    private var timer: Timer?
    private var playing = false
    private var usesLiveCapture = false
    private var liveAmplitude: CGFloat = 0
    /// Live RMS is used only after the tap has actually heard audio.
    /// Otherwise bars freeze at ~0 while the tap is silent or permission is pending.
    private var liveArmed = false
    private let frameInterval: TimeInterval = 1.0 / 30.0

    init() {
        var seed = Date().timeIntervalSinceReferenceDate.bitPattern
        if seed == 0 { seed = 1 }
        engine = SimulatedWaveformEngine(seed: seed)
        levels = engine.levels
    }

    deinit {
        timer?.invalidate()
    }

    func setUsesLiveCapture(_ active: Bool) {
        usesLiveCapture = active
        if !active {
            liveAmplitude = 0
            liveArmed = false
        }
    }

    func setLiveAmplitude(_ value: CGFloat) {
        liveAmplitude = min(max(value, 0), 1)
        if liveAmplitude > 0.06 {
            liveArmed = true
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        playing = isPlaying
        if isPlaying {
            startTimer()
            return
        }
        // Keep ticking so bars ease down instead of snapping to a line.
        if timer == nil {
            startTimer()
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            self?.step()
        }
        timer.tolerance = frameInterval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        step()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        levels = engine.tick(
            dt: frameInterval,
            playing: playing,
            liveAmplitude: (usesLiveCapture && liveArmed) ? liveAmplitude : nil
        )
        if !playing, levels.allSatisfy({ abs($0 - SimulatedWaveformEngine.idleLevel) < 0.03 }) {
            stopTimer()
        }
    }
}

/// Maps a single drive value onto the existing 7 bars (same source as the art shadow).
struct LiveWaveformMapper {
    static let barCount = SimulatedWaveformEngine.barCount
    /// Symmetric: index 0 == 6, 1 == 5, 2 == 4.
    static let weights: [CGFloat] = [0.58, 0.84, 1.0, 0.70, 1.0, 0.84, 0.58]

    var levels: [CGFloat]
    private var previous: CGFloat = 0
    private var slow: CGFloat = 0
    private var spike: CGFloat = 0

    init() {
        levels = Array(repeating: SimulatedWaveformEngine.idleLevel, count: Self.barCount)
    }

    mutating func tick(dt: TimeInterval, amplitude: CGFloat) -> [CGFloat] {
        let instant = min(1, max(0, amplitude))
        // Verse floor lags hits so a loud mix settles at medium height, not the ceiling.
        slow += (instant - slow) * min(1, CGFloat(dt) * 1.6)
        let flux = abs(instant - previous)
        previous = instant
        spike = min(1, spike * CGFloat(exp(-dt * 8.2)) + flux * 4.6)
        let lift = max(0, instant - slow)

        for i in 0..<((Self.barCount + 1) / 2) {
            let w = Self.weights[i]
            let dist = i
            var target = 0.14 + slow * w * 0.36
            target += lift * (dist == 1 ? 0.78 : dist == 2 ? 0.66 : 0.50)
            target += spike * (dist == 1 ? 0.46 : dist == 2 ? 0.34 : 0.20)
            target = min(1, max(0.08, target))
            let rate: CGFloat = target > levels[i] ? 28 : 12
            levels[i] += (target - levels[i]) * min(1, CGFloat(dt) * rate)
        }
        SimulatedWaveformEngine.mirror(&levels)
        return levels
    }
}

enum WaveformLayout {
    /// 7 stored bars, mirrored. A 6-bar row skips the center so the outer pair still matches.
    static func level(at displayIndex: Int, displayCount: Int, stored: [CGFloat]) -> CGFloat {
        guard !stored.isEmpty else { return SimulatedWaveformEngine.idleLevel }
        if displayCount == 6, stored.count == 7 {
            let map = [0, 1, 2, 4, 5, 6]
            let i = min(max(displayIndex, 0), map.count - 1)
            return stored[map[i]]
        }
        let i = min(max(displayIndex, 0), stored.count - 1)
        return stored[i]
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}

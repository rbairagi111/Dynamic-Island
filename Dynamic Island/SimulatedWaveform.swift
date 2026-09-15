import Foundation
import Combine

/// Equalizer silhouette. Live audio sets overall energy; each candle expands and
/// collapses on its own schedule (YouTube-style), so the left side is not stuck tall.
struct SimulatedWaveformEngine {
    static let barCount = 7
    static let idleLevel: CGFloat = 0.2

    private(set) var levels: [CGFloat]
    private var time: TimeInterval = 0
    private var wasPlaying = false
    private var rng: SplitMix64
    private var live = LiveWaveformMapper()
    private var candles = IndependentCandles(seed: 0xC0FFEE)

    init(seed: UInt64 = 0xC0FFEE) {
        let s = seed == 0 ? 1 : seed
        levels = Array(repeating: Self.idleLevel, count: Self.barCount)
        rng = SplitMix64(state: s)
        candles = IndependentCandles(seed: s &+ 0x9E37)
    }

    /// Advance one frame. `dt` is seconds (e.g. 1/30).
    /// Prefer `liveBands` (per-tab spectrum). Scalar `liveAmplitude` is legacy.
    mutating func tick(
        dt: TimeInterval,
        playing: Bool,
        liveAmplitude: CGFloat? = nil,
        liveBands: [CGFloat]? = nil
    ) -> [CGFloat] {
        let step = max(dt, 1.0 / 120.0)
        time += step

        if playing, let liveBands, liveBands.count == Self.barCount {
            levels = live.tick(dt: step, bands: liveBands)
            return levels
        }

        if playing, let liveAmplitude {
            levels = live.tick(dt: step, amplitude: liveAmplitude)
            return levels
        }

        if playing && !wasPlaying {
            candles.kickstart(at: time, rng: &rng)
        }
        wasPlaying = playing

        guard playing else {
            for i in 0..<Self.barCount {
                levels[i] += (Self.idleLevel - levels[i]) * min(1, CGFloat(step) * 3.6)
            }
            candles.clearPulses()
            return levels
        }

        levels = candles.tick(dt: step, time: time, drive: 1, levels: levels, rng: &rng)
        return levels
    }

    /// Copy the left half onto the right (legacy scalar live path only).
    static func mirror(_ levels: inout [CGFloat]) {
        let n = levels.count
        guard n > 1 else { return }
        for i in 0..<(n / 2) {
            levels[n - 1 - i] = levels[i]
        }
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
    private var liveBands: [CGFloat]?
    /// Live feed is used only after the analyser has actually heard audio.
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
            liveBands = nil
            liveArmed = false
        }
    }

    func setLiveAmplitude(_ value: CGFloat) {
        liveAmplitude = min(max(value, 0), 1)
        liveBands = nil
        // System tap is authoritative once we feed it — arm even at 0 so a
        // quiet dual video tile sits near idle instead of fake-dancing.
        liveArmed = true
    }

    /// Per-source spectrum (7 bands). Drives bars independently of any other tile.
    func setLiveBands(_ bands: [CGFloat]) {
        guard bands.count == Self.barCount else { return }
        liveBands = bands.map { min(max($0, 0), 1) }
        liveArmed = true
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
        let armed = usesLiveCapture && liveArmed
        levels = engine.tick(
            dt: frameInterval,
            playing: playing,
            liveAmplitude: armed && liveBands == nil ? liveAmplitude : nil,
            liveBands: armed ? liveBands : nil
        )
        if !playing, levels.allSatisfy({ abs($0 - SimulatedWaveformEngine.idleLevel) < 0.03 }) {
            stopTimer()
        }
    }
}

/// Maps live audio onto the existing 7 bars.
struct LiveWaveformMapper {
    static let barCount = SimulatedWaveformEngine.barCount
    /// Symmetric weights used by the scalar (legacy) amplitude path.
    static let weights: [CGFloat] = [0.58, 0.84, 1.0, 0.70, 1.0, 0.84, 0.58]

    var levels: [CGFloat]
    private var previous: CGFloat = 0
    private var slow: CGFloat = 0
    private var spike: CGFloat = 0
    private var time: TimeInterval = 0
    private var rng: SplitMix64
    private var candles: IndependentCandles

    init(seed: UInt64 = 0xA11FE) {
        levels = Array(repeating: SimulatedWaveformEngine.idleLevel, count: Self.barCount)
        let s = seed == 0 ? 1 : seed
        rng = SplitMix64(state: s)
        candles = IndependentCandles(seed: s &+ 0xC0FF)
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

    /// YouTube-style candles: mix loudness sets how high peaks can go; each bar
    /// expands/collapses on its own clock. Not a left=bass spectrogram.
    mutating func tick(dt: TimeInterval, bands: [CGFloat]) -> [CGFloat] {
        var input = bands
        if input.count < Self.barCount {
            input.append(contentsOf: Array(repeating: 0, count: Self.barCount - input.count))
        } else if input.count > Self.barCount {
            input = Array(input.prefix(Self.barCount))
        }

        let step = max(dt, 1.0 / 120.0)
        time += step

        var sum: CGFloat = 0
        var peak: CGFloat = 0
        for v in input {
            let x = min(1, max(0, v))
            sum += x
            peak = max(peak, x)
        }
        let mean = sum / CGFloat(Self.barCount)
        // Overall drive from the mix — not which frequency sits on the left.
        let raw = min(1, max(0, mean * 0.40 + peak * 0.60))
        // Lift mid loudness so expansions still reach the old near-full height.
        let drive = min(1, CGFloat(pow(Double(raw), 0.55)) * 1.08)

        levels = candles.tick(dt: step, time: time, drive: drive, levels: levels, rng: &rng)
        return levels
    }
}

/// Per-candle expand/collapse. Shared by simulated and live-band paths.
private struct IndependentCandles {
    private var pulse: [CGFloat]
    private var nextPulseAt: [TimeInterval]
    private var pulseDecay: [Double]
    private var phase: [Double]
    private var speed: [Double]
    private var attack: [CGFloat]
    private var release: [CGFloat]

    init(seed: UInt64) {
        let n = SimulatedWaveformEngine.barCount
        pulse = Array(repeating: 0, count: n)
        nextPulseAt = Array(repeating: 0.05, count: n)
        pulseDecay = Array(repeating: 3.2, count: n)
        phase = Array(repeating: 0, count: n)
        speed = Array(repeating: 1, count: n)
        attack = Array(repeating: 16, count: n)
        release = Array(repeating: 5, count: n)
        var rng = SplitMix64(state: seed == 0 ? 1 : seed)
        for i in 0..<n {
            phase[i] = rng.next(in: 0...(2 * Double.pi))
            speed[i] = rng.next(in: 0.55...1.65)
            pulseDecay[i] = rng.next(in: 2.6...4.8)
            attack[i] = CGFloat(rng.next(in: 14...20))
            release[i] = CGFloat(rng.next(in: 5.0...9.0))
            nextPulseAt[i] = rng.next(in: 0.02...0.45)
        }
    }

    mutating func clearPulses() {
        for i in 0..<pulse.count { pulse[i] = 0 }
    }

    mutating func kickstart(at time: TimeInterval, rng: inout SplitMix64) {
        for i in 0..<pulse.count {
            pulse[i] = CGFloat(rng.next(in: 0.70...1.0))
            nextPulseAt[i] = time + rng.next(in: 0.02...0.40)
        }
    }

    mutating func tick(
        dt: TimeInterval,
        time: TimeInterval,
        drive: CGFloat,
        levels: [CGFloat],
        rng: inout SplitMix64
    ) -> [CGFloat] {
        var out = levels
        let n = SimulatedWaveformEngine.barCount
        let drive = min(1, max(0, drive))

        for i in 0..<n {
            if time >= nextPulseAt[i] {
                firePulse(at: i, time: time, rng: &rng)
            }
            pulse[i] *= CGFloat(exp(-dt * pulseDecay[i]))

            let t = time * speed[i]
            let p = phase[i]
            let wander =
                0.40 * (0.5 + 0.5 * sin(t * 1.73 + p))
                + 0.35 * (0.5 + 0.5 * sin(t * 2.91 + p * 1.35))
                + 0.25 * (0.5 + 0.5 * sin(t * 4.67 + p * 0.7))
            let w = CGFloat(wander)

            // Low rest between hits; expansions still punch near full height.
            var target = 0.05 + drive * (0.04 + 0.12 * w)
            target += pulse[i] * drive * (0.94 + 0.06 * w)
            target = min(1, max(0.04, target))

            let rate = target > out[i] ? attack[i] : release[i]
            out[i] += (target - out[i]) * min(1, CGFloat(dt) * rate)
        }
        return out
    }

    private mutating func firePulse(at i: Int, time: TimeInterval, rng: inout SplitMix64) {
        let amp = CGFloat(rng.next(in: 0.90...1.0))
        pulse[i] = amp
        // Longer gaps so a bar can fully collapse before its next expand.
        nextPulseAt[i] = time + rng.next(in: 0.20...0.90)
        // Occasional soft couple so pairs sometimes rise together, not always.
        if rng.next(in: 0...1) < 0.16 {
            let j = i + (rng.next(in: 0...1) < 0.5 ? -1 : 1)
            if j >= 0, j < pulse.count {
                pulse[j] = max(pulse[j], amp * CGFloat(rng.next(in: 0.45...0.85)))
            }
        }
    }
}

enum WaveformLayout {
    /// Maps display index into stored levels. A 6-bar row skips the center slot.
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

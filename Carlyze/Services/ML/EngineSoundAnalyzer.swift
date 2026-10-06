import AVFoundation
import Accelerate
import SoundAnalysis
import CoreML

/// Records the engine with AGC disabled (`.measurement` mode) so the level is physically meaningful.
final class EngineRecorder {
    private let engine = AVAudioEngine()
    private(set) var samples: [Float] = []
    private(set) var sampleRate: Double = 44_100
    var onLevel: ((Float) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        samples.removeAll()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: ch, count: n))
            let rms = vDSP.rootMeanSquare(chunk)
            DispatchQueue.main.async {
                self.samples.append(contentsOf: chunk)
                self.onLevel?(rms)
            }
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

/// Signal-processing + ML analysis of an idle engine recording.
///
/// DSP indicators (always available, no model needed):
///  • Idle RPM — firing frequency from the envelope's autocorrelation. 4-stroke: f_fire = RPM/60 × cyl/2
///  • Idle stability — variation of the envelope period across 1-s windows
///  • Misfire — periodic missing pulses: energy dips at the cam-cycle rate (RPM/120)
///  • Knock / rod noise — sharp high-frequency transients (crest factor of the 4–10 kHz band)
///  • Belt squeal — strong narrow tonal peak between 2–6 kHz (spectral flatness very low)
///  • Tappet tick — regular HF clicks at cam frequency
/// ML (optional, better): `EngineSound.mlmodel` trained with Create ML on labelled clips (see MLTraining/).
struct EngineSoundAnalyzer {
    let cylinders: Int

    func analyze(samples: [Float], sampleRate: Double) async -> EngineSoundAssessment {
        var r = EngineSoundAssessment()
        r.durationSec = Double(samples.count) / sampleRate
        guard r.durationSec >= 5 else { r.issues = ["Recording too short (need ≥ 10 s of idle)."]; return r }

        // Envelope at 1 kHz
        let hop = Int(sampleRate / 1000)
        let env: [Float] = stride(from: 0, to: samples.count - hop, by: hop).map {
            vDSP.rootMeanSquare(samples[$0..<($0 + hop)])
        }
        let envRate = 1000.0

        // 1. Firing frequency via autocorrelation per 1-s window (RPM 500–1500 → f_fire)
        let cyl = Double(max(cylinders, 1))
        let fMin = 500.0 / 60 * cyl / 2, fMax = 1500.0 / 60 * cyl / 2
        var windowRPM: [Double] = []
        let win = Int(envRate)
        for start in stride(from: 0, to: env.count - win, by: win / 2) {
            let w = Array(env[start..<(start + win)])
            if let f = dominantPeriodicity(w, rate: envRate, fMin: fMin, fMax: fMax) {
                windowRPM.append(f * 60 * 2 / cyl)
            }
        }
        if !windowRPM.isEmpty {
            let mean = windowRPM.reduce(0, +) / Double(windowRPM.count)
            let sd = sqrt(windowRPM.map { pow($0 - mean, 2) }.reduce(0, +) / Double(windowRPM.count))
            r.estimatedIdleRPM = mean
            r.idleStability = max(0, min(1, 1 - (sd / mean) * 8))   // 12.5 % CV → 0
        }

        // 2. Misfire: energy of cycle-to-cycle dips. Compare each firing pulse to the local median.
        if let rpm = r.estimatedIdleRPM {
            let pulse = Int(envRate / (rpm / 60 * cyl / 2))
            if pulse > 2 {
                let peaks = stride(from: 0, to: env.count - pulse, by: pulse).map { env[$0..<($0 + pulse)].max() ?? 0 }
                let med = peaks.map { Double($0) }.median
                let weak = peaks.filter { Double($0) < med * 0.55 }.count
                r.misfireIndex = min(1, Double(weak) / Double(max(peaks.count, 1)) * 6)
            }
        }

        // 3. Spectral features on 4096-point frames
        let spec = averageSpectrum(samples, sampleRate: sampleRate)
        let bin = sampleRate / Double(spec.count * 2)
        func band(_ lo: Double, _ hi: Double) -> ArraySlice<Float> {
            spec[Int(lo / bin)..<min(spec.count, Int(hi / bin))]
        }
        let total = spec.reduce(0, +) + 1e-9
        let squealBand = band(2000, 6000)
        let flatness = spectralFlatness(Array(squealBand))
        let squealShare = Double(squealBand.max() ?? 0) / Double(total)
        r.beltSquealIndex = max(0, min(1, (0.25 - flatness) * 4 * min(1, squealShare * 40)))

        // 4. Knock / tappet: HF band transients (crest factor)
        let hf = highPass(samples, sampleRate: sampleRate, cutoff: 4000)
        let hfEnv: [Float] = stride(from: 0, to: hf.count - hop, by: hop).map { vDSP.maximumMagnitude(hf[$0..<($0 + hop)]) }
        let hfRMS = vDSP.rootMeanSquare(hfEnv) + 1e-9
        let transients = hfEnv.filter { $0 > hfRMS * 3.5 }.count
        let perSec = Double(transients) / r.durationSec
        if let rpm = r.estimatedIdleRPM {
            let camHz = rpm / 120
            // Ticks locked to the cam frequency → valve train (tappet); irregular heavy transients → knock.
            let ratio = perSec / max(camHz, 1)
            r.tappetTickIndex = max(0, min(1, 1 - abs(ratio - 1) )) * min(1, perSec / 3)
        }
        r.knockIndex = max(0, min(1, (perSec - 2) / 20)) * (1 - r.tappetTickIndex * 0.5)

        // 5. Optional Core ML sound classifier
        if let labels = await classify(samples: samples, sampleRate: sampleRate) { r.mlLabels = labels }

        // Issues list (plain-language)
        func ml(_ k: String) -> Double { r.mlLabels[k] ?? 0 }
        if max(r.knockIndex, ml("knock")) > 0.5 { r.issues.append("Knocking detected — possible rod/bearing wear or detonation. Get a mechanic to confirm.") }
        if max(r.misfireIndex, ml("misfire")) > 0.45 { r.issues.append("Irregular firing (misfire) — check spark plugs, coils, injectors, compression.") }
        if r.idleStability < 0.6, r.estimatedIdleRPM != nil { r.issues.append("Unstable / hunting idle — possible vacuum leak, dirty throttle body or sensor fault.") }
        if max(r.beltSquealIndex, ml("belt_squeal")) > 0.5 { r.issues.append("Belt squeal — worn or loose serpentine/fan belt or tensioner.") }
        if max(r.tappetTickIndex, ml("tappet")) > 0.55 { r.issues.append("Valve-train ticking — low oil, worn lifters/tappets or valve clearance.") }
        if ml("exhaust_leak") > 0.5 { r.issues.append("Exhaust leak / puffing sound.") }
        if let rpm = r.estimatedIdleRPM, rpm > 1150 { r.issues.append("High idle (\(Int(rpm)) rpm) — normal only on a cold engine.") }
        return r
    }

    // MARK: DSP helpers

    private func dominantPeriodicity(_ x: [Float], rate: Double, fMin: Double, fMax: Double) -> Double? {
        let mean = vDSP.mean(x)
        let c = vDSP.add(-mean, x)
        let minLag = Int(rate / fMax), maxLag = min(c.count - 1, Int(rate / fMin))
        guard maxLag > minLag else { return nil }
        let e0 = vDSP.dot(c, c)
        guard e0 > 0 else { return nil }
        var best = (lag: 0, v: Float(0))
        for lag in minLag...maxLag {
            let v = vDSP.dot(Array(c[0..<(c.count - lag)]), Array(c[lag..<c.count])) / e0
            if v > best.v { best = (lag, v) }
        }
        return best.v > 0.2 ? rate / Double(best.lag) : nil
    }

    private func averageSpectrum(_ x: [Float], sampleRate: Double) -> [Float] {
        let n = 4096
        guard x.count >= n, let dft = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self) else {
            return [Float](repeating: 0, count: 2048)
        }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        var acc = [Float](repeating: 0, count: n / 2)
        var frames = 0
        let zeros = [Float](repeating: 0, count: n)
        for start in stride(from: 0, to: x.count - n, by: n) {
            let frame = vDSP.multiply(Array(x[start..<(start + n)]), window)
            let out = dft.transform(inputReal: frame, inputImaginary: zeros)
            let mags = zip(out.real.prefix(n / 2), out.imaginary.prefix(n / 2)).map { sqrt($0 * $0 + $1 * $1) }
            acc = vDSP.add(acc, mags)
            frames += 1
        }
        return frames > 0 ? vDSP.divide(acc, Float(frames)) : acc
    }

    private func spectralFlatness(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return 1 }
        let logMean = s.map { log(Double($0) + 1e-9) }.reduce(0, +) / Double(s.count)
        let mean = Double(s.reduce(0, +)) / Double(s.count) + 1e-9
        return exp(logMean) / mean
    }

    private func highPass(_ x: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        // Simple one-pole high-pass; adequate for transient detection.
        let rc = 1 / (2 * Double.pi * cutoff), dt = 1 / sampleRate
        let a = Float(rc / (rc + dt))
        var y = [Float](repeating: 0, count: x.count)
        for i in 1..<x.count { y[i] = a * (y[i - 1] + x[i] - x[i - 1]) }
        return y
    }

    // MARK: Core ML sound classification

    private func classify(samples: [Float], sampleRate: Double) async -> [String: Double]? {
        guard let model = BundledModel.engineSound.load(),
              let request = try? SNClassifySoundRequest(mlModel: model),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = SoundObserver()
        try? analyzer.add(request, withObserver: observer)
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return observer.averaged()
    }
}

private final class SoundObserver: NSObject, SNResultsObserving {
    private var sums: [String: Double] = [:]
    private var n = 0
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        n += 1
        for c in r.classifications { sums[c.identifier, default: 0] += c.confidence }
    }
    func averaged() -> [String: Double] { n == 0 ? [:] : sums.mapValues { $0 / Double(n) } }
}

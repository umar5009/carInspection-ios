import CoreMotion
import Observation
import Foundation

/// "Bounce test" using the phone's accelerometer.
/// Place the phone flat on the wing/boot above a wheel, press the body down firmly, release.
/// Healthy dampers stop the body within ~1 rebound (damping ratio ζ ≈ 0.25–0.5).
/// Worn dampers let it oscillate 2–4 times (ζ < 0.15).
@Observable
final class SuspensionTester {
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var z: [Double] = []
    private(set) var isRecording = false
    private(set) var liveValue: Double = 0

    func record(seconds: Double = 5, completion: @escaping (_ zeta: Double, _ oscillations: Int) -> Void) {
        guard motion.isDeviceMotionAvailable else { completion(0, 0); return }
        z.removeAll()
        isRecording = true
        motion.deviceMotionUpdateInterval = 1.0 / 100
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            self.z.append(m.userAcceleration.z)
            self.liveValue = m.userAcceleration.z
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.motion.stopDeviceMotionUpdates()
            self.isRecording = false
            let result = Self.damping(self.z, rate: 100)
            completion(result.zeta, result.oscillations)
        }
    }

    /// Logarithmic decrement from successive positive peaks after the largest excursion (the release).
    static func damping(_ raw: [Double], rate: Double) -> (zeta: Double, oscillations: Int) {
        guard raw.count > 100 else { return (0, 0) }
        // Low-pass (moving average 5 samples) to remove hand jitter.
        let x = raw.indices.map { i -> Double in
            let lo = max(0, i - 2), hi = min(raw.count - 1, i + 2)
            return raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        guard let release = x.indices.max(by: { abs(x[$0]) < abs(x[$1]) }) else { return (0, 0) }
        let a0 = abs(x[release])
        guard a0 > 0.05 else { return (0, 0) }  // no push detected
        var peaks: [Double] = []
        let minGap = Int(rate * 0.3)
        var last = release
        var i = release + 1
        while i < x.count - 1 {
            if abs(x[i]) > abs(x[i - 1]), abs(x[i]) >= abs(x[i + 1]), i - last >= minGap, abs(x[i]) > a0 * 0.08 {
                peaks.append(abs(x[i])); last = i
            }
            i += 1
        }
        let seq = [a0] + peaks
        guard seq.count >= 2 else { return (0.7, 0) }  // stopped immediately → very well damped
        // Half-cycle decrement: use pairs of consecutive half-peaks → δ_half; full δ = 2·δ_half
        var deltas: [Double] = []
        for k in 0..<(seq.count - 1) where seq[k + 1] > 0 { deltas.append(log(seq[k] / seq[k + 1])) }
        let delta = 2 * deltas.reduce(0, +) / Double(deltas.count)
        let zeta = delta / sqrt(4 * .pi * .pi + delta * delta)
        return (max(0, min(1, zeta)), peaks.count / 2)
    }

    static func score(zeta: Double) -> Double {
        switch zeta {
        case 0.3...: 10
        case 0.22..<0.3: 8.5 + (zeta - 0.22) / 0.08 * 1.5
        case 0.15..<0.22: 6.5 + (zeta - 0.15) / 0.07 * 2
        case 0.08..<0.15: 4 + (zeta - 0.08) / 0.07 * 2.5
        default: 3
        }
    }
}

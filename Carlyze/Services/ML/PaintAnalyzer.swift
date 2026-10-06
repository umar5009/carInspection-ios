import UIKit
import Accelerate

/// Detects colour and texture mismatch between neighbouring painted panels seen in the SAME photo
/// (same light, same white balance). Refinished panels usually differ slightly in hue/lightness
/// (metallic flake orientation, clear-coat gloss) and in "orange-peel" texture.
///
/// This is an *indicator*. A magnetic paint-thickness gauge is the ground truth, so the
/// report upgrades a suspicion to "Repainted" only when a gauge reading confirms it.
struct PaintAnalyzer {

    typealias Lab = (L: Double, a: Double, b: Double)

    struct PanelSample { let part: CarPart; let lab: Lab; let texture: Double; let photo: Int }

    /// Extracts a robust colour sample for each detected body panel.
    func samples(image: UIImage, parts: [(CarPart, CGRect)], photoIndex: Int) -> [PanelSample] {
        guard let px = RGBAImage(image) else { return [] }
        return Self.samples(pixels: px, parts: parts).map {
            PanelSample(part: $0.part, lab: $0.lab, texture: $0.texture, photo: photoIndex)
        }
    }

    /// Samples the centre of each painted panel (25 % inset avoids gaps, trims and the neighbouring panel).
    static func samples(pixels px: RGBAImage, parts: [(CarPart, CGRect)]) -> [(part: CarPart, box: CGRect, lab: Lab, texture: Double)] {
        parts.compactMap { (item: (CarPart, CGRect)) -> (part: CarPart, box: CGRect, lab: Lab, texture: Double)? in
            let (part, box) = item
            guard part.group == .body, !part.comparablePeers.isEmpty else { return nil }
            let r = box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25)
            guard r.width > 0.03, r.height > 0.03, let s = px.sample(region: r) else { return nil }
            return (part: part, box: box, lab: s.lab, texture: s.texture)
        }
    }

    /// Compares every panel with comparable panels inside the same photo; returns per-part ΔE and texture ratio.
    func compare(_ all: [PanelSample]) -> [CarPart: (deltaE: Double, texture: Double)] {
        var deltas: [CarPart: [Double]] = [:]
        var textures: [CarPart: [Double]] = [:]
        for (_, samples) in Dictionary(grouping: all, by: \.photo) {
            for (part, r) in Self.attribute(samples.map { (part: $0.part, lab: $0.lab, texture: $0.texture) }) {
                deltas[part, default: []].append(r.deltaE)
                textures[part, default: []].append(r.texture)
            }
        }
        var out: [CarPart: (deltaE: Double, texture: Double)] = [:]
        for (part, d) in deltas { out[part] = (d.median, textures[part]?.median ?? 1) }
        return out
    }

    /// A clear colour or texture difference between two panels.
    static func isMismatch(deltaE d: Double, texture t: Double) -> Bool {
        d > 5.0 || (d > 3.0 && (t > 1.35 || t < 0.7))
    }

    /// Compares panels seen in ONE photo and decides which panel a difference belongs to.
    ///
    /// When a front door is repainted, the fender and the rear door each differ from it too.
    /// The panel that differs from the MOST peers is the odd one out; the others keep a low value.
    /// With only two panels in view there is no way to tell, so both keep the difference.
    static func attribute(_ samples: [(part: CarPart, lab: Lab, texture: Double)]) -> [CarPart: (deltaE: Double, texture: Double)] {
        struct Pair { let peer: CarPart; let d: Double; let t: Double }
        var pairs: [CarPart: [Pair]] = [:]
        for s in samples {
            for p in samples where p.part != s.part && s.part.comparablePeers.contains(p.part) {
                let t = p.texture > 0 ? s.texture / p.texture : 1
                pairs[s.part, default: []].append(Pair(peer: p.part, d: ciede2000(s.lab, p.lab), t: t))
            }
        }
        let odd: [CarPart: Int] = pairs.mapValues { list in list.filter { isMismatch(deltaE: $0.d, texture: $0.t) }.count }
        var out: [CarPart: (deltaE: Double, texture: Double)] = [:]
        for (part, list) in pairs {
            let mine = odd[part] ?? 0
            let kept: [(Double, Double)] = list.map { pair in
                if (odd[pair.peer] ?? 0) > mine { return (min(pair.d, 2.0), 1.0) }   // the peer is the odd one out
                return (pair.d, pair.t)
            }
            out[part] = (kept.map { $0.0 }.median, kept.map { $0.1 }.median)
        }
        return out
    }

    /// Converts ΔE / texture / optional gauge value to a status.
    /// Only a gauge reading can say "repainted" or "filler"; the camera alone can only ask for a check.
    static func status(deltaE: Double?, texture: Double?, gauge: Double?, baselineGauge: Double?) -> PaintStatus {
        if let g = gauge {
            // Capped at 140 µm: on a fully re-sprayed ("shower") car the roof and the median are re-sprayed too,
            // so an uncapped baseline would make every panel look original.
            let base = min(baselineGauge ?? 110, 140)
            if g > max(400, base * 3.5) { return .bodyFiller }
            if g > max(180, base * 1.6) { return .repainted }
            if g < 70 { return .suspectedRepaint }  // cut-and-polished or thin re-spray
            return .original                        // normal factory thickness wins over a camera colour difference
        }
        guard let d = deltaE else { return .notScanned }
        return isMismatch(deltaE: d, texture: texture ?? 1) ? .suspectedRepaint : .original
    }

    // MARK: CIEDE2000

    static func ciede2000(_ x: (L: Double, a: Double, b: Double), _ y: (L: Double, a: Double, b: Double)) -> Double {
        let deg = Double.pi / 180
        let C1 = hypot(x.a, x.b), C2 = hypot(y.a, y.b)
        let Cm = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cm, 7) / (pow(Cm, 7) + pow(25, 7))))
        let a1 = (1 + G) * x.a, a2 = (1 + G) * y.a
        let c1 = hypot(a1, x.b), c2 = hypot(a2, y.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / deg
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(x.b, a1), h2 = hue(y.b, a2)
        let dL = y.L - x.L, dC = c2 - c1
        var dh = 0.0
        if c1 * c2 != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * sqrt(c1 * c2) * sin(dh / 2 * deg)
        let Lm = (x.L + y.L) / 2, cm = (c1 + c2) / 2
        var hm = h1 + h2
        if c1 * c2 != 0 {
            if abs(h1 - h2) > 180 { hm = (h1 + h2 < 360) ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2 }
            else { hm = (h1 + h2) / 2 }
        }
        let T = 1 - 0.17 * cos((hm - 30) * deg) + 0.24 * cos(2 * hm * deg)
            + 0.32 * cos((3 * hm + 6) * deg) - 0.20 * cos((4 * hm - 63) * deg)
        let dTheta = 30 * exp(-pow((hm - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(cm, 7) / (pow(cm, 7) + pow(25, 7)))
        let Sl = 1 + 0.015 * pow(Lm - 50, 2) / sqrt(20 + pow(Lm - 50, 2))
        let Sc = 1 + 0.045 * cm
        let Sh = 1 + 0.015 * cm * T
        let Rt = -sin(2 * dTheta * deg) * Rc
        return sqrt(pow(dL / Sl, 2) + pow(dC / Sc, 2) + pow(dH / Sh, 2) + Rt * (dC / Sc) * (dH / Sh))
    }
}

// MARK: - Pixel helper

struct RGBAImage {
    let width: Int, height: Int
    let data: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.normalized(maxSide: 1024).cgImage else { return nil }
        width = cg.width; height = cg.height
        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let w = cg.width, h = cg.height
        let drawn: Bool = buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Store rows top-to-bottom so normalised rects (top-left origin) sample the right pixels.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard drawn else { return nil }
        data = buf
    }

    /// Median Lab (ignoring highlights / deep shadows) and mean |Laplacian| of L as a texture measure.
    func sample(region r: CGRect) -> (lab: (L: Double, a: Double, b: Double), texture: Double)? {
        let x0 = max(1, Int(r.minX * Double(width))), x1 = min(width - 2, Int(r.maxX * Double(width)))
        let y0 = max(1, Int(r.minY * Double(height))), y1 = min(height - 2, Int(r.maxY * Double(height)))
        guard x1 > x0 + 4, y1 > y0 + 4 else { return nil }
        let step = max(1, (x1 - x0) * (y1 - y0) / 6000)
        var Ls: [Double] = [], As: [Double] = [], Bs: [Double] = []
        var lap: [Double] = []
        func L(_ x: Int, _ y: Int) -> Double { lab(x, y).L }
        var i = 0
        for y in y0...y1 {
            for x in x0...x1 {
                i += 1
                guard i % step == 0 else { continue }
                let c = lab(x, y)
                guard c.L > 18, c.L < 92 else { continue } // skip reflections/shadows
                Ls.append(c.L); As.append(c.a); Bs.append(c.b)
                lap.append(abs(4 * c.L - L(x - 1, y) - L(x + 1, y) - L(x, y - 1) - L(x, y + 1)))
            }
        }
        guard Ls.count > 50 else { return nil }
        // Drop the brightest 15 % (sky reflections, glare on clear coat) before taking the colour.
        let cut = Ls.sorted()[Int(Double(Ls.count) * 0.85)]
        var keptL: [Double] = [], keptA: [Double] = [], keptB: [Double] = [], keptLap: [Double] = []
        for k in Ls.indices where Ls[k] <= cut {
            keptL.append(Ls[k]); keptA.append(As[k]); keptB.append(Bs[k]); keptLap.append(lap[k])
        }
        guard keptL.count > 40 else { return nil }
        return ((keptL.median, keptA.median, keptB.median), keptLap.reduce(0, +) / Double(keptLap.count))
    }

    func lab(_ x: Int, _ y: Int) -> (L: Double, a: Double, b: Double) {
        let o = (y * width + x) * 4
        func lin(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin(data[o]), g = lin(data[o + 1]), b = lin(data[o + 2])
        let X = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let Z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(X), fy = f(Y), fz = f(Z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

extension Array where Element == Double {
    var median: Double {
        guard !isEmpty else { return 0 }
        let s = sorted()
        return count % 2 == 1 ? s[count / 2] : (s[count / 2 - 1] + s[count / 2]) / 2
    }
}

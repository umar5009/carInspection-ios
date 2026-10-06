import UIKit

/// How the panels in a frame were found.
enum PanelSource: String {
    /// The CarPartsYOLO model found each panel in the image.
    case model
    /// No model installed: panels are assumed from how the user framed this side of the car.
    case framing
}

/// Finds painted panels in a photo or camera frame.
///
/// With `CarPartsYOLO` in the app bundle, every panel is detected wherever it is in the frame.
/// Without it, the app falls back to fixed framing zones, but only after Vision confirms a car is
/// actually in view (so a wall or a room is never "scanned").
enum PanelLocator {
    struct Located {
        var carVisible: Bool
        var parts: [(CarPart, CGRect)]
        var source: PanelSource?
    }

    /// Loaded once. Vision requests are not thread-safe, so callers use one serial queue for live frames.
    static let partsModel = ObjectDetector(.parts, minConfidence: 0.4)

    static var hasModel: Bool { partsModel.isReady }

    static func locate(_ image: UIImage, side: ScanSide?) -> Located {
        if partsModel.isReady {
            var best: [CarPart: (box: CGRect, confidence: Double)] = [:]
            for d in partsModel.detect(in: image) {
                guard let part = part(for: d.label, box: d.box, side: side) else { continue }
                if (best[part]?.confidence ?? 0) < d.confidence { best[part] = (d.box, d.confidence) }
            }
            let parts = best.map { ($0.key, $0.value.box) }
            let bodyCount = parts.filter { $0.0.group == .body }.count
            return Located(carVisible: bodyCount >= 2, parts: parts, source: .model)
        }
        guard let side, CarDetector.sees(image, labels: CarDetector.vehicles) else {
            return Located(carVisible: false, parts: [], source: nil)
        }
        return Located(carVisible: true, parts: LivePaintScanner.zones(for: side), source: .framing)
    }

    /// Maps a model label to a panel. Labels without a side (the public `carparts-seg` set has
    /// `front_door`, `back_door`, `front_light`, `back_light`) are resolved from the side being scanned
    /// and the position in the frame.
    static func part(for label: String, box: CGRect, side: ScanSide?) -> CarPart? {
        if let p = CarPart(modelLabel: label) { return p }
        let onViewerLeft = box.midX < 0.5
        switch (label.lowercased(), side) {
        case ("front_door", .left?): return .frontLeftDoor
        case ("front_door", .right?): return .frontRightDoor
        case ("back_door", .left?): return .rearLeftDoor
        case ("back_door", .right?): return .rearRightDoor
        // Facing the nose, the car's right is on the viewer's left.
        case ("front_light", .front?): return onViewerLeft ? .headlightRight : .headlightLeft
        // Behind the car, the car's left is on the viewer's left.
        case ("back_light", .rear?): return onViewerLeft ? .taillightLeft : .taillightRight
        default: return nil
        }
    }
}

/// Compares comparable painted panels in one camera frame.
/// Bumpers and mirrors are left out: they are plastic and often a different shade even on an original car.
/// The bonnet is only compared with the roof, never with the fenders, because it faces the sky.
enum LivePaintScanner {
    struct Region: Identifiable {
        var id: CarPart { part }
        let part: CarPart
        let box: CGRect
        let deltaE: Double
        let textureRatio: Double
        /// This frame's panel differs from the comparable panels beside it.
        let mismatched: Bool
    }

    struct Result {
        var carVisible: Bool
        /// Panels that could be colour-compared in this frame.
        var regions: [Region]
        /// Every panel located in the frame (used for gauge targeting and labels), top-left normalised boxes.
        var panels: [(CarPart, CGRect)]
        var source: PanelSource?
    }

    static func analyze(_ image: UIImage, side: ScanSide?) -> Result {
        let located = PanelLocator.locate(image, side: side)
        guard located.carVisible, let pixels = RGBAImage(image) else {
            return Result(carVisible: located.carVisible, regions: [], panels: located.parts, source: located.source)
        }
        let samples = PaintAnalyzer.samples(pixels: pixels, parts: located.parts)
        let compared = PaintAnalyzer.attribute(samples.map { (part: $0.part, lab: $0.lab, texture: $0.texture) })
        let regions: [Region] = samples.compactMap { s in
            guard let c = compared[s.part] else { return nil }
            return Region(part: s.part, box: s.box, deltaE: c.deltaE, textureRatio: c.texture,
                          mismatched: PaintAnalyzer.isMismatch(deltaE: c.deltaE, texture: c.texture))
        }
        return Result(carVisible: true, regions: regions, panels: located.parts, source: located.source)
    }

    /// Normalised boxes (top-left origin) for the painted metal on this face of the car,
    /// used only when no parts model is installed. Left/right are the car's left and right, not the viewer's.
    static func zones(for side: ScanSide) -> [(CarPart, CGRect)] {
        switch side {
        case .front:
            // Facing the nose: the car's right is on the viewer's left.
            return [
                (.frontRightFender, CGRect(x: 0.10, y: 0.34, width: 0.24, height: 0.32)),
                (.hood, CGRect(x: 0.34, y: 0.28, width: 0.32, height: 0.30)),
                (.frontLeftFender, CGRect(x: 0.66, y: 0.34, width: 0.24, height: 0.32))
            ]
        case .right:
            // Standing on the car's right, the front of the car is to the viewer's right.
            return slices([.rearRightQuarter, .rearRightDoor, .frontRightDoor, .frontRightFender])
        case .rear:
            // Standing behind the car: the car's left is on the viewer's left.
            return [
                (.rearLeftQuarter, CGRect(x: 0.10, y: 0.34, width: 0.24, height: 0.32)),
                (.trunk, CGRect(x: 0.34, y: 0.30, width: 0.32, height: 0.30)),
                (.rearRightQuarter, CGRect(x: 0.66, y: 0.34, width: 0.24, height: 0.32))
            ]
        case .left:
            return slices([.frontLeftFender, .frontLeftDoor, .rearLeftDoor, .rearLeftQuarter])
        }
    }

    /// Four panels across the middle band of a side view, where the painted skin is (below the glass).
    private static func slices(_ parts: [CarPart]) -> [(CarPart, CGRect)] {
        let width = 0.84 / CGFloat(parts.count)
        return parts.enumerated().map { index, part in
            (part, CGRect(x: 0.08 + width * CGFloat(index), y: 0.42, width: width, height: 0.26))
        }
    }
}

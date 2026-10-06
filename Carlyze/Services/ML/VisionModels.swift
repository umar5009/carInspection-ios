import Foundation
import Vision
import CoreML
import UIKit

/// Names of the Core ML models expected in the app bundle (drag the .mlpackage files produced by
/// MLTraining/ into the Xcode target — Xcode compiles them to .mlmodelc automatically).
enum BundledModel: String, CaseIterable {
    case damage = "CarDamageYOLO"         // YOLO11 detection: scratch, dent, crack, glass_shatter, lamp_broken, tire_flat, rust
    case parts = "CarPartsYOLO"           // YOLO11 detection: 29 exterior part labels (see CarPart.init(modelLabel:))
    case treadWear = "TreadWear"          // image classifier: good, fair, worn, uneven
    case interior = "InteriorCondition"   // multi-label classifier: seat_tear, stain, worn_steering, worn_pedals, dash_warning, clean
    case engineSound = "EngineSound"      // Create ML sound classifier: healthy, knock, misfire, belt_squeal, tappet, exhaust_leak

    var isAvailable: Bool { Bundle.main.url(forResource: rawValue, withExtension: "mlmodelc") != nil }

    func load() -> MLModel? {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "mlmodelc") else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all            // Neural Engine when available
        return try? MLModel(contentsOf: url, configuration: cfg)
    }
}

struct Detection {
    let label: String
    let confidence: Double
    /// Normalised rect with top-left origin (UIKit convention).
    let box: CGRect
}

/// Runs any YOLO model exported with `nms=True` (outputs VNRecognizedObjectObservation).
final class ObjectDetector {
    private let request: VNCoreMLRequest?
    let isReady: Bool

    init(_ model: BundledModel, minConfidence: Float = 0.35) {
        if let ml = model.load(), let vn = try? VNCoreMLModel(for: ml) {
            let r = VNCoreMLRequest(model: vn)
            r.imageCropAndScaleOption = .scaleFill
            request = r
            isReady = true
        } else {
            request = nil
            isReady = false
        }
        self.minConfidence = minConfidence
    }
    private let minConfidence: Float

    func detect(in image: UIImage) -> [Detection] {
        guard let request, let cg = image.cgImage else { return [] }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation)
        try? handler.perform([request])
        let obs = request.results as? [VNRecognizedObjectObservation] ?? []
        return obs.compactMap { o in
            guard let top = o.labels.first, top.confidence >= minConfidence else { return nil }
            let b = o.boundingBox // bottom-left origin
            let rect = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            return Detection(label: top.identifier, confidence: Double(top.confidence), box: rect)
        }
    }
}

/// Generic image classifier (single or multi-label). Returns label → probability.
final class ImageClassifier {
    private let request: VNCoreMLRequest?
    var isReady: Bool { request != nil }

    init(_ model: BundledModel) {
        if let ml = model.load(), let vn = try? VNCoreMLModel(for: ml) {
            let r = VNCoreMLRequest(model: vn)
            r.imageCropAndScaleOption = .centerCrop
            request = r
        } else { request = nil }
    }

    func classify(_ image: UIImage) -> [String: Double] {
        guard let request, let cg = image.cgImage else { return [:] }
        try? VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation).perform([request])
        let obs = request.results as? [VNClassificationObservation] ?? []
        return Dictionary(obs.map { ($0.identifier, Double($0.confidence)) }, uniquingKeysWith: max)
    }
}

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    /// Returns an upright copy so pixel coordinates match normalised Vision boxes.
    func normalized(maxSide: CGFloat = 1600) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

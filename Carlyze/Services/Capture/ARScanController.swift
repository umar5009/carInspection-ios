import ARKit
import SceneKit
import SwiftUI
import UIKit

/// A painted panel located in the current AR frame, in view (screen) coordinates.
struct ViewPanel: Identifiable {
    var id: CarPart { part }
    let part: CarPart
    let rect: CGRect
    /// The panel had a comparable panel beside it in this frame, so its colour was checked.
    let comparable: Bool
    /// This frame's colour differs from the comparable panels.
    let mismatched: Bool
}

/// Drives the AR walk-around: runs ARKit world tracking, analyses about two frames a second,
/// works out which side of the car the user is facing, and pins labels onto panels in 3-D.
///
/// ARKit's visual-inertial tracking does not drift like the compass, so the side stays correct for a
/// whole walk-around, and labels stay on the panel as the user moves.
final class ARScanController: NSObject, ObservableObject, ARSessionDelegate {
    let sceneView = ARSCNView(frame: .zero)

    @Published private(set) var panels: [ViewPanel] = []
    @Published private(set) var carVisible = false
    @Published private(set) var source: PanelSource?
    @Published private(set) var side: ScanSide = .front
    @Published private(set) var trackingNote: String? = "Starting AR… move the phone slowly."
    @Published var manualSide: ScanSide?

    var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    var effectiveSide: ScanSide { manualSide ?? side }

    /// Called on the main queue after each analysed frame: result, upright frame, side, heading (nil if tracking is limited).
    var onResult: ((LivePaintScanner.Result, UIImage, ScanSide, Double?) -> Void)?

    private let queue = DispatchQueue(label: "carlyze.arscan", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var busy = false
    private var lastAnalysis: TimeInterval = 0
    private var frontHeading: Double?
    private var latestHeading: Double?
    private var pins: [CarPart: SCNNode] = [:]

    override init() {
        super.init()
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = false
        sceneView.antialiasingMode = .multisampling4X
    }

    func start() {
        guard isSupported else {
            trackingNote = "This iPhone does not support AR tracking."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        sceneView.session.pause()
    }

    /// Call while standing at the nose of the car, facing it.
    func markFront() {
        frontHeading = latestHeading
        manualSide = nil
        side = .front
    }

    /// The panel under the centre crosshair (or the nearest one within reach), for gauge readings.
    var targetPanel: CarPart? {
        let c = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        if let inside = panels.filter({ $0.rect.contains(c) }).min(by: { area($0.rect) < area($1.rect) }) {
            return inside.part
        }
        guard let near = panels.min(by: { distance($0.rect, c) < distance($1.rect, c) }), distance(near.rect, c) < 90 else { return nil }
        return near.part
    }

    // MARK: Labels in 3-D

    func hasPin(_ part: CarPart) -> Bool { pins[part] != nil }

    /// Pins a floating label on the panel if it is in view. Replaces an existing label for that panel.
    @discardableResult
    func pin(_ part: CarPart, text: String, color: UIColor) -> Bool {
        guard let panel = panels.first(where: { $0.part == part }) else { return false }
        let point = CGPoint(x: panel.rect.midX, y: panel.rect.midY)
        guard let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
              let hit = sceneView.session.raycast(query).first else { return false }
        let node = Self.labelNode(text: text, color: color)
        let t = hit.worldTransform.columns.3
        node.simdPosition = SIMD3<Float>(t.x, t.y, t.z)
        pins[part]?.removeFromParentNode()
        pins[part] = node
        sceneView.scene.rootNode.addChildNode(node)
        return true
    }

    func clearPins() {
        pins.values.forEach { $0.removeFromParentNode() }
        pins = [:]
    }

    private static func labelNode(text: String, color: UIColor) -> SCNNode {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 44, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 26
        let size = CGSize(width: ceil(textSize.width) + pad * 2, height: ceil(textSize.height) + pad)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2).fill()
            (text as NSString).draw(at: CGPoint(x: pad, y: pad / 2), withAttributes: attrs)
        }
        let width: CGFloat = 0.32
        let plane = SCNPlane(width: width, height: width * size.height / size.width)
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false   // stay readable in front of the car body
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.renderingOrder = 100
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        node.constraints = [billboard]
        return node
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let heading = Self.heading(of: frame.camera)
        latestHeading = heading
        let tracked: Bool
        if case .normal = frame.camera.trackingState { tracked = true } else { tracked = false }
        // The walk starts at the front (the screen says so); "This is the front" re-sets it.
        if frontHeading == nil, tracked { frontHeading = heading }
        if let front = frontHeading {
            var turned = (heading - front).truncatingRemainder(dividingBy: 360)
            if turned < 0 { turned += 360 }
            let s = ScanSide(clockwiseDegrees: turned)
            if s != side { side = s }
        }

        guard !busy, frame.timestamp - lastAnalysis >= 0.45 else { return }
        let viewport = sceneView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        lastAnalysis = frame.timestamp
        let display = frame.displayTransform(for: .portrait, viewportSize: viewport)
        guard let image = uprightImage(frame.capturedImage) else { return }
        busy = true
        let scanSide = effectiveSide
        queue.async { [weak self] in
            let result = LivePaintScanner.analyze(image, side: scanSide)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.apply(result, display: display, viewport: viewport)
                self.onResult?(result, image, scanSide, tracked ? heading : nil)
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            trackingNote = nil
        case .notAvailable:
            trackingNote = "AR tracking is not available."
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: trackingNote = "Move a little slower."
            case .insufficientFeatures: trackingNote = "Point at the car in good light."
            case .initializing, .relocalizing: trackingNote = "Starting AR… move the phone slowly."
            @unknown default: trackingNote = nil
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingNote = error.localizedDescription
    }

    // MARK: Helpers

    private func apply(_ result: LivePaintScanner.Result, display: CGAffineTransform, viewport: CGSize) {
        carVisible = result.carVisible
        source = result.source
        guard result.carVisible else { panels = []; return }
        var compared: [CarPart: LivePaintScanner.Region] = [:]
        for region in result.regions { compared[region.part] = region }
        panels = result.panels.filter { $0.0.group == .body }.map { item in
            let region = compared[item.0]
            return ViewPanel(part: item.0, rect: Self.viewRect(item.1, display: display, viewport: viewport),
                             comparable: region != nil, mismatched: region?.mismatched ?? false)
        }
    }

    /// The camera image rotated upright for a portrait phone and scaled to 720 px, for analysis.
    private func uprightImage(_ buffer: CVPixelBuffer) -> UIImage? {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let scale = 720 / max(upright.extent.width, upright.extent.height)
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Converts a box in the upright image (normalised, top-left origin) to view coordinates.
    /// The captured image is landscape; upright (u, v) is captured (v, 1 − u). `displayTransform`
    /// then maps captured-image coordinates to the (aspect-filled) view.
    static func viewRect(_ box: CGRect, display: CGAffineTransform, viewport: CGSize) -> CGRect {
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
        let points = corners.map { c -> CGPoint in
            let n = CGPoint(x: c.y, y: 1 - c.x).applying(display)
            return CGPoint(x: n.x * viewport.width, y: n.y * viewport.height)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Compass-style heading of the camera in degrees (clockwise seen from above), 0..<360.
    static func heading(of camera: ARCamera) -> Double {
        let z = camera.transform.columns.2          // the camera looks along −z
        let forwardX = Double(-z.x), forwardZ = Double(-z.z)
        var degrees = atan2(forwardX, -forwardZ) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

extension ScanSide {
    /// Degrees turned clockwise (seen from above) since facing the front of the car.
    init(clockwiseDegrees degrees: Double) {
        switch degrees {
        case 45..<135: self = .right
        case 135..<225: self = .rear
        case 225..<315: self = .left
        default: self = .front
        }
    }
}

/// Hosts the AR view in SwiftUI.
struct ARScanViewContainer: UIViewRepresentable {
    let controller: ARScanController
    func makeUIView(context: Context) -> ARSCNView { controller.sceneView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

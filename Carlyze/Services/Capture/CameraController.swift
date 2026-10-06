import AVFoundation
import SwiftUI
import UIKit

/// Lightweight photo camera with live preview used by the guided scan screens.
final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "carlyze.camera.frames", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var lastFrameTime: CFAbsoluteTime = 0
    /// Called on the main queue with a downscaled upright frame, about twice a second.
    var onVideoFrame: ((UIImage) -> Void)?
    @Published var authorized = false

    func configure(streamsFrames: Bool = false) async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run { authorized = granted }
        guard granted, session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = streamsFrames ? .high : .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            // Lock white balance per session later if needed; auto is fine for relative comparisons in one frame.
        }
        if streamsFrames {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90 // portrait, matching the preview
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.maxPhotoQualityPrioritization = .balanced
            }
        } else if session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .quality
        }
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func stop() { DispatchQueue.global().async { self.session.stopRunning() } }

    func capture() async -> UIImage? {
        guard session.outputs.contains(where: { $0 is AVCapturePhotoOutput }) else { return nil }
        return await withCheckedContinuation { c in
            continuation = c
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        continuation?.resume(returning: img)
        continuation = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameTime >= 0.45 else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now
        guard let image = thumbnail(from: buffer) else { return }
        DispatchQueue.main.async { [weak self] in self?.onVideoFrame?(image) }
    }

    private func thumbnail(from buffer: CVPixelBuffer) -> UIImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let extent = source.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        let scale = min(1, 720 / max(extent.width, extent.height))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = gravity
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.videoGravity = gravity
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Samples sharp frames from an imported walk-around video.
enum VideoFrameExtractor {
    static func frames(from url: URL, every seconds: Double = 0.75, max count: Int = 60) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let total = CMTimeGetSeconds(duration)
        let step = max(seconds, total / Double(count))
        var images: [UIImage] = []
        var t = 0.0
        while t < total {
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let img = UIImage(cgImage: cg)
                if sharpness(img) > 6 { images.append(img) }   // drop motion-blurred frames
            }
            t += step
        }
        return images
    }

    /// Mean absolute Laplacian on a small grayscale copy — cheap blur detector.
    static func sharpness(_ image: UIImage) -> Double {
        guard let px = RGBAImage(image.normalized(maxSide: 320)) else { return 0 }
        var sum = 0.0, n = 0
        func g(_ x: Int, _ y: Int) -> Double {
            let o = (y * px.width + x) * 4
            return 0.299 * Double(px.data[o]) + 0.587 * Double(px.data[o + 1]) + 0.114 * Double(px.data[o + 2])
        }
        for y in stride(from: 1, to: px.height - 1, by: 2) {
            for x in stride(from: 1, to: px.width - 1, by: 2) {
                sum += abs(4 * g(x, y) - g(x - 1, y) - g(x + 1, y) - g(x, y - 1) - g(x, y + 1)); n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }
}

import SwiftUI
import AVFoundation

/// One continuous inspection. A voice explains each step. The user takes the photo,
/// and the flow moves on. The last step records the engine.
struct GuidedInspectionView: View {
    init(session: InspectionSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
    }
    @Bindable var session: InspectionSession
    var onClose: () -> Void

    @StateObject private var cam = CameraController()
    @StateObject private var voice = GuideVoice()
    @State private var index = 0
    @State private var capturing = false
    @State private var rejectMessage: String?
    @State private var flash = false
    @State private var analyzing = false
    @State private var progress = 0.0
    @State private var status = "Preparing the grade sheet…"
    @State private var report: InspectionReport?
    @State private var engineStarted = false
    @State private var recording = false
    @State private var listenSeconds = 0
    @State private var levels: [Float] = []
    @State private var recorder = EngineRecorder()
    @State private var showVerify = false

    private var cue: GuideCue { GuideCue.script[index] }
    private var showingEngine: Bool {
        if case .engine = cue.kind { return report == nil && !analyzing }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if let report {
                    ReportView(report: report)
                        .safeAreaInset(edge: .bottom) {
                            PrimaryButton(title: "Verify: paint gauge, OBD & checks", icon: "checkmark.seal") { showVerify = true }
                                .padding(.horizontal).padding(.bottom, 8)
                                .background(Theme.bg.opacity(0.95))
                        }
                } else if analyzing {
                    AnalyzingOverlay(progress: progress, status: status)
                } else if showingEngine {
                    engineScreen
                } else {
                    cameraScreen
                }
            }
            .navigationTitle(report == nil ? "Step \(index + 1) of \(GuideCue.script.count)" : "Grade sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(report == nil ? "Close" : "Done", action: onClose)
                }
            }
        }
        .fullScreenCover(isPresented: $showVerify) {
            // Same session: everything already captured is kept, and a new report is generated from there.
            InspectionFlowView(session: session) { showVerify = false }
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            beginStep()
        }
        .task { await cam.configure() }
        .onDisappear {
            voice.stop()
            cam.stop()
            if recording { recorder.stop() }
        }
    }

    // MARK: Camera

    private var cameraScreen: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(index), total: Double(GuideCue.script.count))
                .tint(Theme.accent)
                .padding(.horizontal)
            ZStack {
                CameraPreview(session: cam.session, gravity: .resizeAspectFill)
                framingBrackets
                if flash { Color.white.ignoresSafeArea() }
            }
            .clipped()
            instructionBar
        }
    }

    private var framingBrackets: some View {
        Brackets()
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 280, height: 210)
            .allowsHitTesting(false)
    }

    private var instructionBar: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(cue.title).font(.headline).foregroundStyle(.white)
                Text(cue.speech).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(statusLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(rejectMessage == nil ? Theme.accent : Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await takePhoto() } } label: {
                Circle().fill(.white).frame(width: 72, height: 72)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: 4).padding(-6))
            }
            .disabled(capturing)
            .opacity(capturing ? 0.45 : 1)
            Button("Skip this step", action: skip)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(capturing)
        }
        .padding()
        .background(Theme.bg)
    }

    private var statusLine: String {
        if capturing { return "Checking this photo…" }
        if let rejectMessage { return rejectMessage }
        return "Line up the shot, then tap the button"
    }

    // MARK: Engine

    private var engineScreen: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(Theme.accent)
            Text(cue.title).font(.title2.bold()).foregroundStyle(.white)
            Text(cue.speech).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.suffix(48).indices, id: \.self) { i in
                    Capsule().fill(Theme.accent).frame(width: 3, height: max(4, min(100, CGFloat(levels.suffix(48)[i]) * 900)))
                }
            }
            .frame(height: 110)
            Text(recording ? "Listening \(listenSeconds) / 15" : "Getting ready to listen")
                .font(.headline.monospacedDigit()).foregroundStyle(.white)
            Spacer()
            Button("Skip engine") { Task { await finish() } }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .padding()
    }

    // MARK: Flow

    private func beginStep() {
        capturing = false
        rejectMessage = nil
        let step = index
        let current = GuideCue.script[step]
        voice.say(current.speech) {
            guard index == step else { return }
            if case .engine = current.kind { Task { await recordEngine() } }
        }
    }

    private func takePhoto() async {
        guard !capturing else { return }
        capturing = true
        let kind = GuideCue.script[index].kind
        guard let shot = await cam.capture() else {
            capturing = false
            return
        }
        if let subject = subject(for: kind) {
            let accepted = await Self.matches(shot, subject)
            if !accepted {
                capturing = false
                rejectMessage = subject.rejection
                voice.say(subject.rejection)
                return
            }
        }
        rejectMessage = nil
        await store(shot, kind: kind)
        flash = true
        try? await Task.sleep(for: .milliseconds(160))
        flash = false
        advance()
    }

    private func store(_ image: UIImage, kind: GuideCue.Kind) async {
        switch kind {
        case .vin:
            DispatchQueue.global(qos: .userInitiated).async {
                guard let vin = TextScanner.findVehicleID(in: TextScanner.recognize(image)) else { return }
                DispatchQueue.main.async {
                    session.vehicle.vin = vin
                    if let year = TextScanner.modelYear(fromVIN: vin) { session.vehicle.year = year }
                }
            }
        case .exterior(let side):
            // Panels are located and compared when the report is built (see InspectionAnalyzer).
            session.addExteriorPhoto(image, side: side)
            var covered = session.coveredExteriorSides
            covered.insert(side)
            session.coveredExteriorSides = covered
        case .glass(let part):
            session.glassPhotos[part] = image
        case .tyre(let part):
            session.tyreSidewallPhotos[part] = image
        case .cabin:
            session.interiorPhotos.append(image)
        case .dashboard:
            session.dashboardPhoto = image
        case .engine:
            break
        }
    }

    private func subject(for kind: GuideCue.Kind) -> CaptureSubject? {
        switch kind {
        case .vin: .vin
        case .exterior: .vehicle
        case .glass: .glass
        case .tyre: .tyre
        case .cabin, .dashboard: .cabin
        case .engine: nil
        }
    }

    private static func matches(_ image: UIImage, _ subject: CaptureSubject) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: subject.matches(image))
            }
        }
    }

    private func skip() {
        voice.stop()
        guard !capturing else { return }
        if case .engine = cue.kind {
            Task { await finish() }
        } else {
            capturing = true
            advance()
        }
    }

    private func advance() {
        guard index + 1 < GuideCue.script.count else {
            Task { await finish() }
            return
        }
        index += 1
        beginStep()
    }

    private func recordEngine() async {
        guard !engineStarted else { return }
        engineStarted = true
        guard await AVAudioApplication.requestRecordPermission() else {
            voice.say("I can't use the microphone, so the grade sheet will not include the engine.") { Task { await finish() } }
            return
        }
        cam.stop()
        recording = true
        listenSeconds = 0
        levels = []
        recorder.onLevel = { levels.append($0) }
        do { try recorder.start() } catch {
            recording = false
            await finish()
            return
        }
        for second in 1...15 {
            try? await Task.sleep(for: .seconds(1))
            if analyzing || report != nil { break }
            listenSeconds = second
        }
        recorder.stop()
        recording = false
        session.engineSamples = recorder.samples
        session.engineSampleRate = recorder.sampleRate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        await finish()
    }

    @MainActor private func finish() async {
        guard report == nil, !analyzing else { return }
        analyzing = true
        voice.stop()
        if recording { recorder.stop(); recording = false }
        cam.stop()
        let built = await InspectionAnalyzer().run(session) { value, message in
            progress = value
            status = message
        }
        ReportStore.shared.save(built)
        let sheet = JapanGradeSheet.make(built)
        analyzing = false
        report = built
        if sheet.grade == "—" {
            voice.say("No car was detected, so there is no inspection grade. Retake the exterior with the vehicle filling the frame.")
        } else {
            voice.say("Inspection complete. The grade is \(sheet.grade). Interior \(sheet.interior). \(sheet.meaning).")
        }
    }
}

private struct GuideCue {
    let title: String
    let speech: String
    let kind: Kind
    enum Kind {
        case vin, cabin, dashboard, engine
        case exterior(ScanSide)
        case glass(CarPart)
        case tyre(CarPart)
    }

    static let script: [GuideCue] = [
        .init(title: "VIN", speech: "Point at the VIN or chassis number: on the dashboard at the bottom of the windscreen, or on the plate in the engine bay. Tap the button when it is in frame.", kind: .vin),
        .init(title: "Front", speech: "Stand at the front of the car. Fit the bonnet and both front wings in the frame, then tap the button.", kind: .exterior(.front)),
        .init(title: "Right side", speech: "Walk to the right side. Show the whole side, from the front wheel to the back wheel, then tap the button.", kind: .exterior(.right)),
        .init(title: "Rear", speech: "Stand behind the car. Fit the boot and both rear corners in the frame, then tap the button.", kind: .exterior(.rear)),
        .init(title: "Left side", speech: "Walk to the left side and show the whole side. Tap the button when it looks right.", kind: .exterior(.left)),
        .init(title: "Windscreen stamp", speech: "Move close to the small printed stamp in a corner of the windscreen, then tap the button.", kind: .glass(.windshield)),
        .init(title: "Rear glass stamp", speech: "Now the stamp in the corner of the rear window. Tap the button when it is readable.", kind: .glass(.rearWindow)),
        .init(title: "Front-left tyre", speech: "Show the front left tyre sidewall, with the DOT letters readable, then tap the button.", kind: .tyre(.wheelFrontLeft)),
        .init(title: "Front-right tyre", speech: "Now the front right tyre sidewall. Tap the button when it is in frame.", kind: .tyre(.wheelFrontRight)),
        .init(title: "Rear-left tyre", speech: "Rear left tyre sidewall. Tap the button when you are ready.", kind: .tyre(.wheelRearLeft)),
        .init(title: "Rear-right tyre", speech: "Rear right tyre sidewall. This is the last wheel. Tap the button.", kind: .tyre(.wheelRearRight)),
        .init(title: "Interior", speech: "Open the driver's door and show the seat, the steering wheel, and the pedals, then tap the button.", kind: .cabin),
        .init(title: "Dashboard", speech: "Turn the ignition on and show the dashboard, including the odometer, then tap the button.", kind: .dashboard),
        .init(title: "Engine", speech: "Start the engine and hold the phone near the open bonnet. I will listen for fifteen seconds. Please keep quiet.", kind: .engine)
    ]
}

private final class GuideVoice: NSObject, AVSpeechSynthesizerDelegate, ObservableObject {
    private let synth = AVSpeechSynthesizer()
    private var generation = 0
    private var pending: (token: Int, callback: () -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String, then: (() -> Void)? = nil) {
        generation += 1
        let token = generation
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        if let then { pending = (token, then) } else { pending = nil }
        synth.speak(utterance)
    }

    func stop() {
        generation += 1
        pending = nil
        synth.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pending, pending.token == generation else { return }
            let callback = pending.callback
            self.pending = nil
            callback()
        }
    }
}


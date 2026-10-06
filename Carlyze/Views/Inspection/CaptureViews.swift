import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Single shot camera sheet

struct SingleShotCamera: View {
    init(title: String, keepOpen: Bool = false, onCapture: @escaping (UIImage) -> Void) {
        self.title = title; self.keepOpen = keepOpen; self.onCapture = onCapture
    }
    let title: String
    var keepOpen = false
    let onCapture: (UIImage) -> Void
    @StateObject private var cam = CameraController()
    @Environment(\.dismiss) private var dismiss
    @State private var flash = false

    var body: some View {
        ZStack {
            CameraPreview(session: cam.session).ignoresSafeArea()
            Brackets().stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 280, height: 200)
            VStack {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold)).padding(10).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                }.padding()
                Spacer()
                Button {
                    Task {
                        if let img = await cam.capture() {
                            onCapture(img)
                            withAnimation(.easeOut(duration: 0.2)) { flash = true }
                            try? await Task.sleep(for: .milliseconds(200))
                            flash = false
                            if !keepOpen { dismiss() }
                        }
                    }
                } label: {
                    Circle().fill(.white).frame(width: 74, height: 74).overlay(Circle().stroke(Theme.accent, lineWidth: 4).padding(-6))
                }
                .padding(.bottom, 30)
            }
            if flash { Color.white.opacity(0.6).ignoresSafeArea() }
        }
        .task { await cam.configure() }
        .onDisappear { cam.stop() }
    }
}

/// Transferable wrapper that copies a picked movie into a temp file.
struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return VideoFile(url: dst)
        }
    }
}

// MARK: - Engine sound

struct EngineSoundView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @State private var recorder = EngineRecorder()
    @State private var recording = false
    @State private var levels: [Float] = []
    @State private var seconds = 0
    @State private var preview: EngineSoundAssessment?
    let target = 20

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Card(title: "How to record", icon: "info.circle") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Engine warm, idling, bonnet open. A/C and radio off.")
                        Text("2. Hold the phone ~30 cm above the engine (not touching).")
                        Text("3. Record \(target) s: 10 s idle, then 2–3 gentle revs to 2,500 rpm.")
                        Text("4. Keep people quiet — voices affect the result.")
                    }.font(.subheadline).foregroundStyle(.secondary)
                }
                // Waveform
                HStack(alignment: .center, spacing: 2) {
                    ForEach(levels.suffix(60).indices, id: \.self) { i in
                        let v = CGFloat(levels.suffix(60)[i])
                        Capsule().fill(Theme.accent).frame(width: 3, height: max(3, min(120, v * 900)))
                    }
                }
                .frame(height: 130).frame(maxWidth: .infinity).background(Theme.card, in: RoundedRectangle(cornerRadius: 16))

                Text(recording ? "Recording… \(seconds)s / \(target)s" : (session.engineSamples.isEmpty ? "Ready" : "Recorded \(Int(Double(session.engineSamples.count) / session.engineSampleRate)) s"))
                    .font(.headline.monospacedDigit()).foregroundStyle(.white)

                PrimaryButton(title: recording ? "Recording…" : "Record engine", icon: "mic.fill") { Task { await record() } }
                    .disabled(recording)

                if let p = preview {
                    Card(title: "Quick result", icon: "waveform.badge.magnifyingglass") {
                        if let rpm = p.estimatedIdleRPM { Text("Estimated idle: \(Int(rpm)) rpm").foregroundStyle(.white) }
                        Text(String(format: "Idle stability %.0f%%", p.idleStability * 100)).foregroundStyle(.secondary)
                        if p.issues.isEmpty { Text("No abnormal sounds detected ✓").foregroundStyle(Theme.accent) }
                        ForEach(p.issues, id: \.self) { Text("• " + $0).foregroundStyle(Theme.warn).font(.subheadline) }
                    }
                }
            }
            .padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Engine sound")
    }

    @MainActor private func record() async {
        guard await AVAudioApplication.requestRecordPermission() else { return }
        levels = []; seconds = 0; recording = true
        recorder.onLevel = { levels.append($0) }
        do { try recorder.start() } catch { recording = false; return }
        for s in 1...target {
            try? await Task.sleep(for: .seconds(1))
            seconds = s
        }
        recorder.stop()
        recording = false
        session.engineSamples = recorder.samples
        session.engineSampleRate = recorder.sampleRate
        preview = await EngineSoundAnalyzer(cylinders: session.vehicle.cylinders)
            .analyze(samples: recorder.samples, sampleRate: recorder.sampleRate)
    }
}

// MARK: - Suspension

struct SuspensionStepView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @State private var tester = SuspensionTester()
    @State private var active: CarPart?
    @State private var countdown = 0
    let corners: [CarPart] = [.wheelFrontLeft, .wheelFrontRight, .wheelRearLeft, .wheelRearRight]

    var body: some View {
        List {
            Section {
                Text("1. Put the phone flat on the body directly above the wheel.\n2. Tap Test, then within 2 s press that corner down hard with both hands and let go.\n3. Keep hands off until the test ends.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(corners) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.displayName.replacingOccurrences(of: " tyre", with: " corner")).foregroundStyle(.white)
                        if let r = session.suspension[c] {
                            Text(String(format: "Damping ζ %.2f · %d rebounds · %.1f/10", r.zeta, r.oscillations, SuspensionTester.score(zeta: r.zeta)))
                                .font(.caption).foregroundStyle(Theme.color(for: SuspensionTester.score(zeta: r.zeta)))
                        }
                    }
                    Spacer()
                    if active == c {
                        Text(countdown > 0 ? "Push in \(countdown)…" : "Release!").font(.caption.bold()).foregroundStyle(Theme.warn)
                    } else {
                        Button("Test") { run(c) }.buttonStyle(.borderedProminent).disabled(active != nil)
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Suspension")
    }

    private func run(_ c: CarPart) {
        active = c; countdown = 2
        Task { @MainActor in
            while countdown > 0 { try? await Task.sleep(for: .seconds(1)); countdown -= 1 }
            tester.record(seconds: 5) { zeta, osc in
                session.suspension[c] = (zeta, osc)
                active = nil
            }
        }
    }
}

// MARK: - OBD

struct OBDStepView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @State private var obd = OBDService()

    var body: some View {
        List {
            Section {
                Text("Plug a Bluetooth-LE OBD-II adapter (ELM327-compatible, e.g. Vgate iCar Pro BLE, OBDLink CX) into the port under the steering column. Ignition ON.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Connect & read codes") { obd.start { session.obd = $0 } }
                    .disabled(obd.state == .scanning || obd.state == .connecting || obd.state == .reading)
            }.listRowBackground(Theme.card)
            Section("Status") {
                Text(stateText).foregroundStyle(.white)
                if let r = session.obd {
                    LabeledContent("Check-engine light", value: r.milOn ? "ON" : "Off")
                    LabeledContent("Fault codes", value: r.troubleCodes.isEmpty ? "None" : r.troubleCodes.joined(separator: ", "))
                    if let t = r.coolantTempC { LabeledContent("Coolant", value: "\(Int(t)) °C") }
                    if let f = r.fuelTrimLongPct { LabeledContent("Long-term fuel trim", value: String(format: "%.1f %%", f)) }
                    if let pending = r.pendingCodes { LabeledContent("Pending codes", value: pending.isEmpty ? "None" : pending.joined(separator: ", ")) }
                    if let d = r.distanceSinceClearedKm { LabeledContent("Driven since codes cleared", value: "\(d) km") }
                    if let m = r.monitorsNotReady { LabeledContent("Self-tests not finished", value: "\(m)") }
                    if let km = r.ecuOdometerKm { LabeledContent("ECU odometer", value: "\(km.formatted()) km") }
                    if r.codesRecentlyCleared {
                        Text("⚠︎ Fault codes look recently cleared. Ask the seller why, and re-scan after a few drives.")
                            .font(.caption).foregroundStyle(Theme.warn)
                    }
                }
            }.listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("OBD-II")
    }

    private var stateText: String {
        switch obd.state {
        case .idle: "Not connected"
        case .scanning: "Searching for adapter…"
        case .connecting: "Connecting…"
        case .reading: "Reading ECU…"
        case .done: "Done ✓"
        case .failed(let m): m
        }
    }
}


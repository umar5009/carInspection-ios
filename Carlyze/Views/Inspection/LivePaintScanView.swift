import SwiftUI
import PhotosUI
import UIKit

/// AR walk-around paint scan.
///
/// • The parts model (or, without it, the framing guide) finds each painted panel live.
/// • Comparable panels are colour-compared in the same frame; a difference must persist across several
///   frames AND two viewing angles before it is flagged, so moving reflections are ignored.
/// • Flagged panels get a floating AR label.
/// • Point the crosshair at a panel and take a paint-gauge reading (Bluetooth, keyboard-mode gauge or typed):
///   the reading is saved to that panel and its label shows the confirmed result.
struct LivePaintScanView: View {
    init(session: InspectionSession) { self.session = session }
    @Bindable var session: InspectionSession
    @StateObject private var ar = ARScanController()
    @State private var gauge = PaintGaugeService()
    @Environment(\.dismiss) private var dismiss

    @State private var dwell: [ScanSide: TimeInterval] = [:]
    @State private var videoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var extracting = false
    @State private var gaugeText = ""
    @State private var gaugeMessage: String?
    @State private var manualTarget: CarPart?
    @State private var showGaugeSheet = false
    @FocusState private var gaugeFieldFocused: Bool

    private var gaugeTarget: CarPart? { manualTarget ?? ar.targetPanel }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ARScanViewContainer(controller: ar).ignoresSafeArea(edges: .horizontal)
                overlay
                crosshair
                VStack {
                    header
                    Spacer()
                }
            }
            .clipped()

            controls
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("AR paint scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { importMenu }
        .overlay { if extracting { AnalyzingOverlay(progress: 0.5, status: "Extracting sharp frames from video…") } }
        .sheet(isPresented: $showGaugeSheet) { GaugeConnectSheet(gauge: gauge) }
        .onAppear {
            ar.onResult = { result, image, side, heading in handle(result, image: image, side: side, heading: heading) }
            ar.start()
            repinSavedReadings()
        }
        .onDisappear {
            ar.onResult = nil
            ar.pause()
            gauge.stopScan()
            gauge.disconnect()
        }
        .onChange(of: gauge.lastReading) { _, reading in
            if let reading { saveGauge(reading.microns) }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task {
                extracting = true
                if let movie = try? await item.loadTransferable(type: VideoFile.self) {
                    for frame in await VideoFrameExtractor.frames(from: movie.url) { session.addExteriorPhoto(frame, side: nil) }
                }
                extracting = false
                videoItem = nil
            }
        }
        .onChange(of: photoItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        session.addExteriorPhoto(image, side: nil)
                    }
                }
                photoItems = []
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ar.effectiveSide.title).font(.headline)
                Spacer()
                if let source = ar.source {
                    Text(source == .model ? "AI panels" : "Framing guide")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((source == .model ? Theme.accent : Theme.warn).opacity(0.25), in: Capsule())
                }
            }
            Text(instruction).font(.caption)
            Text(statusLine).font(.subheadline.weight(.semibold)).foregroundStyle(statusColor)
            if let note = ar.trackingNote {
                Text(note).font(.caption).foregroundStyle(Theme.warn)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }

    private var instruction: String {
        if ar.source == .framing {
            return ar.effectiveSide.instruction + " No parts model is installed, so keep the car framed as described."
        }
        return ar.effectiveSide.instruction
    }

    private var statusLine: String {
        if !ar.carVisible { return "Point the camera so this side of the car fills the frame" }
        let names = session.livePaint.filter(\.value.mismatched).keys.map(\.displayName).sorted()
        if names.isEmpty { return "No colour differences on comparable panels so far" }
        return "Check with gauge: " + names.prefix(2).joined(separator: ", ")
    }

    private var statusColor: Color {
        session.livePaint.values.contains(where: \.mismatched) ? Theme.warn : Theme.accent
    }

    // MARK: Overlay

    private var overlay: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ar.panels) { panel in
                let reading = session.gaugeReadings[panel.part]
                let confirmedMismatch = session.livePaint[panel.part]?.mismatched == true
                let color = boxColor(panel, reading: reading, confirmedMismatch: confirmedMismatch)
                let isTarget = panel.part == gaugeTarget
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color, style: StrokeStyle(lineWidth: isTarget ? 3.5 : (panel.comparable ? 2 : 1),
                                                      dash: panel.mismatched && !confirmedMismatch && reading == nil ? [6, 4] : []))
                    .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(isTarget ? 0.22 : 0.08)))
                    .overlay(alignment: .topLeading) {
                        if isTarget || confirmedMismatch || reading != nil {
                            Text(label(for: panel.part, reading: reading))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(color, in: Capsule())
                                .foregroundStyle(.black)
                                .offset(y: -12)
                        }
                    }
                    .frame(width: max(panel.rect.width, 1), height: max(panel.rect.height, 1))
                    .position(x: panel.rect.midX, y: panel.rect.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var crosshair: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.9), lineWidth: 2).frame(width: 26, height: 26)
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
        }
        .allowsHitTesting(false)
    }

    private func boxColor(_ panel: ViewPanel, reading: Double?, confirmedMismatch: Bool) -> Color {
        if let reading { return Theme.color(for: status(for: reading)) }
        if confirmedMismatch || panel.mismatched { return Theme.warn }
        return panel.comparable ? Theme.accent : Color.white.opacity(0.6)
    }

    private func label(for part: CarPart, reading: Double?) -> String {
        if let reading { return "\(part.displayName) · \(Int(reading)) µm · \(status(for: reading).shortLabel)" }
        if session.livePaint[part]?.mismatched == true { return "\(part.displayName) · check" }
        return part.displayName
    }

    private func status(for microns: Double) -> PaintStatus {
        PaintAnalyzer.status(deltaE: nil, texture: nil, gauge: microns, baselineGauge: InspectionAnalyzer.gaugeBaseline(session.gaugeReadings))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            gaugeBar
            HStack(spacing: 8) {
                ForEach(ScanSide.allCases) { item in
                    Button { ar.manualSide = item } label: {
                        VStack(spacing: 4) {
                            Image(systemName: session.coveredExteriorSides.contains(item) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(session.coveredExteriorSides.contains(item) ? Theme.accent : .secondary)
                            Text(item.title.replacingOccurrences(of: " side", with: ""))
                                .font(.caption2.weight(item == ar.effectiveSide ? .bold : .regular))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(item == ar.effectiveSide ? Theme.accent.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(item == ar.effectiveSide ? Theme.accent : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("This is the front") { ar.markFront() }.font(.caption)
                Spacer()
                if ar.manualSide != nil {
                    Button("Follow my walk") { ar.manualSide = nil }.font(.caption)
                }
            }
            .foregroundStyle(Theme.accent)
            PrimaryButton(title: session.coveredExteriorSides.isEmpty ? "Finish scan" : "Finish scan · \(session.coveredExteriorSides.count)/4 sides", icon: "checkmark") {
                dismiss()
            }
        }
        .padding()
        .background(Theme.bg)
    }

    private var gaugeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "ruler").foregroundStyle(Theme.accent)
                if let target = gaugeTarget {
                    Text("Gauge → \(target.displayName)").font(.subheadline.weight(.semibold)).lineLimit(1)
                } else {
                    Text("Aim the crosshair at a panel").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Follow crosshair") { manualTarget = nil }
                    ForEach(CarPart.allCases.filter { $0.group == .body }) { part in
                        Button(part.displayName) { manualTarget = part }
                    }
                } label: {
                    Image(systemName: manualTarget == nil ? "scope" : "hand.point.up.left.fill")
                }
                Button { showGaugeSheet = true } label: {
                    Image(systemName: gauge.isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(gauge.isConnected ? Theme.accent : .secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("µm (type, or use a keyboard-mode gauge)", text: $gaugeText)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .focused($gaugeFieldFocused)
                    .onSubmit(submitTypedReading)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Button("Save", action: submitTypedReading)
                    .buttonStyle(.borderedProminent)
                    .disabled(gaugeText.isEmpty)
            }
            if let gaugeMessage {
                Text(gaugeMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func submitTypedReading() {
        guard let value = PaintGaugeService.parse(gaugeText) else {
            gaugeMessage = "Enter a thickness in µm, e.g. 120."
            return
        }
        gaugeText = ""
        saveGauge(value)
        gaugeFieldFocused = true   // ready for the next reading from a keyboard-mode gauge
    }

    private func saveGauge(_ microns: Double) {
        guard let part = gaugeTarget else {
            gaugeMessage = "Aim the crosshair at a panel, or pick one with the target button, then measure again."
            return
        }
        if part.surface == .plastic {
            gaugeMessage = "\(part.displayName) is usually plastic: magnetic gauges can't measure it. Reading not saved."
            return
        }
        session.gaugeReadings[part] = microns
        let s = status(for: microns)
        gaugeMessage = "Saved \(Int(microns)) µm → \(part.displayName): \(s.shortLabel)."
        UINotificationFeedbackGenerator().notificationOccurred(s.isConfirmedRepair ? .warning : .success)
        ar.pin(part, text: "\(part.displayName) · \(Int(microns)) µm · \(s.shortLabel)", color: UIColor(Theme.color(for: s)))
        if manualTarget != nil { manualTarget = nil }
    }

    // MARK: Frames

    private func handle(_ result: LivePaintScanner.Result, image: UIImage, side: ScanSide, heading: Double?) {
        guard result.carVisible else { return }
        let newly = session.recordLivePaint(result.regions, heading: heading)
        for part in newly where session.gaugeReadings[part] == nil {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            let delta = session.livePaint[part]?.deltaE ?? 0
            ar.pin(part, text: "\(part.displayName) · check paint · ΔE \(String(format: "%.1f", delta))", color: UIColor(Theme.warn))
        }
        // Labels are only placed when a panel is in view; place any that are still missing.
        for panel in ar.panels where !ar.hasPin(panel.part) {
            if let microns = session.gaugeReadings[panel.part] {
                let s = status(for: microns)
                ar.pin(panel.part, text: "\(panel.part.displayName) · \(Int(microns)) µm · \(s.shortLabel)", color: UIColor(Theme.color(for: s)))
            } else if session.livePaint[panel.part]?.mismatched == true {
                ar.pin(panel.part, text: "\(panel.part.displayName) · check paint", color: UIColor(Theme.warn))
            }
        }
        // Keep one clear frame per side as evidence for the report.
        guard !session.coveredExteriorSides.contains(side) else { return }
        dwell[side, default: 0] += 0.45
        if (dwell[side] ?? 0) >= 1.6 {
            var covered = session.coveredExteriorSides
            covered.insert(side)
            session.coveredExteriorSides = covered
            session.addExteriorPhoto(image, side: side)
        }
    }

    private func repinSavedReadings() {
        // Labels from an earlier visit to this screen are re-placed as panels come into view (see `handle`).
        ar.clearPins()
    }

    @ToolbarContentBuilder private var importMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                PhotosPicker(selection: $photoItems, matching: .images) { Label("Import photos", systemImage: "photo") }
                PhotosPicker(selection: $videoItem, matching: .videos) { Label("Import walk-around video", systemImage: "video") }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
        }
    }
}

/// Pick and connect a Bluetooth paint gauge.
struct GaugeConnectSheet: View {
    let gauge: PaintGaugeService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Turn the gauge on and switch it to Bluetooth mode. Gauges that pair as a keyboard (\"HID mode\") don't need this: pair them in iPhone Settings › Bluetooth and they type into the reading field.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Status") {
                    Text(statusText)
                    if !gauge.lastRaw.isEmpty {
                        LabeledContent("Last data", value: gauge.lastRaw).font(.caption.monospaced())
                    }
                    if let r = gauge.lastReading {
                        LabeledContent("Last reading", value: "\(Int(r.microns)) µm")
                    }
                    if gauge.isConnected {
                        Button("Disconnect", role: .destructive) { gauge.disconnect() }
                    } else {
                        Button(gauge.state == .scanning ? "Scanning…" : "Scan for gauges") { gauge.startScan() }
                            .disabled(gauge.state == .scanning)
                    }
                }
                if !gauge.devices.isEmpty && !gauge.isConnected {
                    Section("Nearby devices") {
                        ForEach(gauge.devices) { device in
                            Button {
                                gauge.connect(device)
                            } label: {
                                HStack {
                                    Text(device.name)
                                    if device.likelyGauge {
                                        Text("gauge").font(.caption2.bold()).padding(.horizontal, 5)
                                            .background(Theme.accent.opacity(0.25), in: Capsule())
                                    }
                                    Spacer()
                                    Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Paint gauge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var statusText: String {
        switch gauge.state {
        case .off: "Not connected"
        case .scanning: "Scanning…"
        case .connecting(let name): "Connecting to \(name)…"
        case .connected(let name): "Connected to \(name). Readings go to the panel under the crosshair."
        case .failed(let message): message
        }
    }
}

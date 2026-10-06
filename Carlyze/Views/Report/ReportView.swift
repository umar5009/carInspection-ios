import SwiftUI

struct ReportView: View {
    init(report: InspectionReport) { self.report = report }
    let report: InspectionReport
    @State private var selected: CarPart?
    @State private var pdfURL: URL?

    var body: some View {
        ScrollView {
            ReportContent(report: report, selected: $selected, interactive: true).padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Inspection report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let pdfURL {
                    ShareLink(item: pdfURL) { Image(systemName: "square.and.arrow.up") }
                } else {
                    ProgressView()
                }
            }
        }
        .task { pdfURL = PDFExporter.export(report) }
    }
}

/// Shared by the on-screen report and the PDF export.
struct ReportContent: View {
    let report: InspectionReport
    @Binding var selected: CarPart?
    var interactive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuctionSheetView(report: report)
            header
            accidentCard
            Card(title: "Condition ratings", icon: "chart.bar.fill") {
                ForEach(report.scores) { ScoreBar(item: $0) }
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                    Text("= verified by scan / measurement").foregroundStyle(.secondary)
                }.font(.caption2)
            }
            bodyMap
            if !report.photoFiles.isEmpty { EvidenceGallery(report: report) }
            panelTable
            if !report.glass.isEmpty { glassCard }
            if !report.tyres.isEmpty { tyreCard }
            engineCard
            if !report.suspension.isEmpty { suspensionCard }
            if let ia = report.interior { interiorCard(ia) }
            disclaimer
        }
    }

    // MARK: Sections

    private var header: some View {
        Card {
            HStack(spacing: 18) {
                ScoreRing(score: report.overall, size: 118)
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.vehicle.title).font(.title3.bold()).foregroundStyle(.white)
                    Text("\(report.vehicle.condition.rawValue) car · \(report.vehicle.mileageKm.formatted()) km").font(.subheadline).foregroundStyle(.secondary)
                    if !report.vehicle.vin.isEmpty { Text("VIN \(report.vehicle.vin)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Text(report.createdAt.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(report.verdict).font(.subheadline.weight(.medium)).foregroundStyle(.white)
        }
    }

    private var accidentCard: some View {
        let color: Color
        switch report.accident {
        case .noSigns: color = Theme.accent
        case .minor: color = Theme.warn
        case .moderate: color = .orange
        case .major: color = Theme.bad
        }
        return Card(title: "Accident & repair history", icon: "car.side.rear.and.collision.and.car.side.front") {
            Text(report.accident.rawValue).font(.headline).foregroundStyle(color)
            if report.accident != .noSigns && report.accidentVerified != true {
                Text("Based on camera colour only. Confirm the flagged panels with a paint gauge before deciding.")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            if report.accidentEvidence.isEmpty {
                Text("No repaint, replaced glass or structural repair signs found in the scanned areas.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(report.accidentEvidence, id: \.self) { Text("• " + $0).font(.subheadline).foregroundStyle(.white) }
        }
    }

    private var bodyMap: some View {
        Card(title: "Body map", icon: "car.top.door.front.left.and.front.right.and.rear.left.and.rear.right.open") {
            HStack(alignment: .top, spacing: 16) {
                CarDiagramView(panels: report.panels, glass: report.glass, tyres: report.tyres, marks: JapanGradeSheet.make(report).marks, selected: $selected)
                    .frame(maxWidth: 170)
                VStack(alignment: .leading, spacing: 10) {
                    DiagramLegend()
                    if interactive, let s = selected { partDetail(s) }
                    else if interactive { Text("Tap a panel for details.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder private func partDetail(_ part: CarPart) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(part.displayName).font(.subheadline.bold()).foregroundStyle(.white)
            if let p = report.panels.first(where: { $0.part == part }) {
                Text("Paint: \(p.paint.label)").font(.caption)
                Text("Part: \(p.replacement.rawValue)").font(.caption)
                ForEach(p.damages) { Text("• \($0.type.displayName) (\(Int($0.confidence * 100))%)").font(.caption) }
                ForEach(p.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            } else if let g = report.glass.first(where: { $0.part == part }) {
                Text(g.replacement.rawValue).font(.caption)
                Text(g.note).font(.caption2).foregroundStyle(.secondary)
            } else if let t = report.tyres.first(where: { $0.position == part }) {
                Text(String(format: "%.1f / 10", t.score)).font(.caption)
                ForEach(t.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text("Not scanned").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
    }

    private var panelTable: some View {
        Card(title: "Panel-by-panel", icon: "list.bullet.rectangle") {
            if report.panels.isEmpty { Text("No exterior scan.").foregroundStyle(.secondary) }
            if let loose = report.unassignedDamages, !loose.isEmpty {
                Text("\(loose.count) more damage mark(s) found that could not be tied to a panel (see photos).")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            ForEach(report.panels) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Circle().fill(Theme.color(for: p.paint)).frame(width: 10, height: 10)
                        Text(p.part.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        Text(p.paint.shortLabel).font(.caption).foregroundStyle(Theme.color(for: p.paint))
                    }
                    if p.replacement == .suspected || p.replacement == .replaced {
                        Text("Part status: \(p.replacement.rawValue)").font(.caption).foregroundStyle(.purple)
                    }
                    if !p.damages.isEmpty {
                        Text(Dictionary(grouping: p.damages, by: \.type).map { "\($0.value.count)× \($0.key.displayName.lowercased())" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(Theme.warn)
                    }
                    ForEach(p.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                }
                Divider().overlay(.white.opacity(0.06))
            }
        }
    }

    private var glassCard: some View {
        Card(title: "Glass — windscreen, rear screen & windows", icon: "rectangle.split.3x1") {
            ForEach(report.glass) { g in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.part.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text([g.brand, g.year.map { "made \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Text(g.note).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(g.replacement.rawValue).font(.caption.bold())
                        .foregroundStyle(g.replacement == .original ? Theme.accent : g.replacement == .unknown ? .secondary : Theme.warn)
                }
            }
        }
    }

    private var tyreCard: some View {
        Card(title: "Tyres", icon: "circle.circle") {
            ForEach(report.tyres) { t in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(t.position.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        Text(String(format: "%.1f / 10", t.score)).font(.subheadline.bold().monospacedDigit()).foregroundStyle(Theme.color(for: t.score))
                    }
                    ForEach(t.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder private var engineCard: some View {
        if report.engine != nil || report.obd?.connected == true {
            Card(title: "Engine", icon: "engine.combustion") {
                if let e = report.engine {
                    VStack(alignment: .leading, spacing: 6) {
                        if let rpm = e.estimatedIdleRPM { row("Idle speed", "\(Int(rpm)) rpm") }
                        row("Idle stability", pct(e.idleStability, goodHigh: true))
                        row("Knock / rod noise", pct(max(e.knockIndex, e.mlLabels["knock"] ?? 0), goodHigh: false))
                        row("Misfire", pct(max(e.misfireIndex, e.mlLabels["misfire"] ?? 0), goodHigh: false))
                        row("Belt squeal", pct(max(e.beltSquealIndex, e.mlLabels["belt_squeal"] ?? 0), goodHigh: false))
                        row("Valve-train tick", pct(max(e.tappetTickIndex, e.mlLabels["tappet"] ?? 0), goodHigh: false))
                    }
                    if e.issues.isEmpty { Text("Engine sounds healthy ✓").foregroundStyle(Theme.accent).font(.subheadline) }
                    ForEach(e.issues, id: \.self) { Text("• " + $0).font(.subheadline).foregroundStyle(Theme.warn) }
                }
                if let o = report.obd, o.connected {
                    Divider().overlay(.white.opacity(0.1))
                    Text("ECU (OBD-II)").font(.subheadline.bold()).foregroundStyle(.white)
                    Text("Check-engine light: \(o.milOn ? "ON" : "off") · Fault codes: \(o.troubleCodes.isEmpty ? "none" : o.troubleCodes.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let pending = o.pendingCodes, !pending.isEmpty {
                        Text("Pending codes: \(pending.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.warn)
                    }
                    if o.codesRecentlyCleared {
                        Text("⚠︎ Codes were cleared recently\(o.distanceSinceClearedKm.map { " (\($0) km ago)" } ?? ""). Faults may be hidden.")
                            .font(.caption).foregroundStyle(Theme.warn)
                    }
                    if let km = o.ecuOdometerKm { Text("ECU odometer: \(km.formatted()) km").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var suspensionCard: some View {
        Card(title: "Suspension / shock absorbers", icon: "arrow.up.and.down.circle") {
            ForEach(report.suspension) { s in
                HStack {
                    Text(s.corner.displayName.replacingOccurrences(of: " tyre", with: "")).foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "ζ %.2f · %d rebounds", s.dampingRatio, s.oscillations)).font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f", s.score)).bold().foregroundStyle(Theme.color(for: s.score))
                }.font(.subheadline)
            }
        }
    }

    private func interiorCard(_ ia: InteriorAssessment) -> some View {
        Card(title: "Interior", icon: "steeringwheel") {
            if let odo = ia.odometerOCR { Text("Odometer read: \(odo.formatted()) km").font(.subheadline).foregroundStyle(.white) }
            Text(ia.mileageConsistency).font(.subheadline).foregroundStyle(ia.mileageConsistency.hasPrefix("⚠︎") ? Theme.warn : .secondary)
            ForEach(ia.labels.filter { $0.value > 0.5 && $0.key != "clean" }.map(\.key).sorted(), id: \.self) {
                Text("• " + $0.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline).foregroundStyle(Theme.warn)
            }
            ForEach(ia.warningLights, id: \.self) { Text("• " + $0).font(.subheadline).foregroundStyle(Theme.bad) }
        }
    }

    private var disclaimer: some View {
        Text("Carlyze combines on-device AI (models: \(report.modelsUsed.isEmpty ? "DSP & OCR only" : report.modelsUsed.joined(separator: ", "))), OCR, sound analysis and sensor measurements. Camera-based repaint detection is an indicator; confirm with a paint thickness gauge. This report does not replace a professional mechanical inspection or a lift check of the chassis.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: helpers
    private func row(_ k: String, _ v: Text) -> some View { HStack { Text(k).foregroundStyle(.secondary); Spacer(); v }.font(.subheadline) }
    private func row(_ k: String, _ v: String) -> some View { row(k, Text(v).foregroundStyle(.white)) }
    private func pct(_ x: Double, goodHigh: Bool) -> Text {
        let good = goodHigh ? x >= 0.7 : x < 0.3
        let mid = goodHigh ? x >= 0.5 : x < 0.5
        return Text("\(Int(x * 100))%").foregroundStyle(good ? Theme.accent : mid ? Theme.warn : Theme.bad).bold()
    }
}


/// The saved walk-around photos with what was found on them: damage boxes and the panels whose paint needs attention.
struct EvidenceGallery: View {
    let report: InspectionReport

    var body: some View {
        Card(title: "Evidence photos", icon: "photo.on.rectangle.angled") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(report.photoFiles.enumerated()), id: \.offset) { index, name in
                        if let image = ReportStore.shared.photo(name) {
                            photo(image, index: index)
                        }
                    }
                }
            }
            Text("Amber/orange/red outline = panel to check or repaired. Small boxes = damage found by the model.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func photo(_ image: UIImage, index: Int) -> some View {
        let height: CGFloat = 200
        let width = height * image.size.width / max(image.size.height, 1)
        let damages = report.panels.flatMap(\.damages).filter { $0.photoIndex == index } + (report.unassignedDamages ?? []).filter { $0.photoIndex == index }
        let flagged = report.panels.filter { $0.photoIndex == index && $0.paint != .original && $0.paint != .notScanned }
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable().frame(width: width, height: height)
            ForEach(flagged) { panel in
                if let box = panel.photoBox?.cgRect {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.color(for: panel.paint), lineWidth: 2)
                        .frame(width: box.width * width, height: box.height * height)
                        .overlay(alignment: .topLeading) {
                            Text(panel.paint.shortLabel).font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).background(Theme.color(for: panel.paint), in: Capsule())
                                .foregroundStyle(.black).offset(y: -9)
                        }
                        .offset(x: box.minX * width, y: box.minY * height)
                }
            }
            ForEach(damages) { d in
                Rectangle()
                    .stroke(Theme.bad, lineWidth: 1.5)
                    .frame(width: d.box.w * width, height: d.box.h * height)
                    .offset(x: d.box.x * width, y: d.box.y * height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

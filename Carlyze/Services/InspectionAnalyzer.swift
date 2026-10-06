import UIKit

/// Runs every model/analyser over a captured session and produces the final report.
struct InspectionAnalyzer {

    func run(_ s: InspectionSession, progress: @escaping @MainActor (Double, String) -> Void) async -> InspectionReport {
        var report = InspectionReport()
        report.vehicle = s.vehicle
        let modelYear = TextScanner.modelYear(fromVIN: s.vehicle.vin) ?? s.vehicle.year
        report.modelsUsed = BundledModel.allCases.filter(\.isAvailable).map(\.rawValue)
        report.photoFiles = ReportStore.shared.savePhotos(s.exteriorPhotos, for: report.id)

        // 1. Exterior: parts + damage + paint
        await progress(0.05, "Detecting body panels and damage…")
        let damageModel = ObjectDetector(.damage, minConfidence: 0.4)
        let paint = PaintAnalyzer()
        var panels: [CarPart: PanelAssessment] = [:]
        var paintSamples: [PaintAnalyzer.PanelSample] = []
        var evidence: [CarPart: (photo: Int, box: CGRect)] = [:]
        let savedPhotoCount = report.photoFiles.count

        for (i, raw) in s.exteriorPhotos.enumerated() {
            let img = raw.normalized()
            let located = PanelLocator.locate(img, side: s.exteriorPhotoSides[i])
            let parts = located.carVisible ? located.parts : []
            for (p, box) in parts where p.group == .body || p.group == .lights {
                if panels[p] == nil { panels[p] = PanelAssessment(part: p) }
                // Keep the photo where the panel is largest as evidence (only saved photos can be shown).
                if i < savedPhotoCount, box.width * box.height > (evidence[p].map { $0.box.width * $0.box.height } ?? 0) {
                    evidence[p] = (i, box)
                }
            }
            paintSamples += paint.samples(image: img, parts: parts, photoIndex: i)

            for d in damageModel.detect(in: img) {
                guard let type = DamageType(rawValue: d.label) else { continue }
                let owner = parts.max { overlap(d.box, $0.1) < overlap(d.box, $1.1) }
                let part = (owner.map { overlap(d.box, $0.1) } ?? 0) > 0.3 ? owner?.0 : nil
                let f = DamageFinding(part: part, type: type, confidence: d.confidence, box: CodableRect(d.box), photoIndex: i)
                if let part { panels[part, default: PanelAssessment(part: part)].damages.append(f) }
                else { report.unassignedDamages = (report.unassignedDamages ?? []) + [f] }
            }
            await progress(0.05 + 0.35 * Double(i + 1) / Double(max(s.exteriorPhotos.count, 1)), "Analysing photo \(i + 1) of \(s.exteriorPhotos.count)…")
        }

        // Paint comparison + live walk-around + gauge confirmation.
        // A confirmed live mismatch (seen from several angles) wins over a milder still-photo reading.
        // A live match fills in panels the still photos never compared.
        var paintResult = paint.compare(paintSamples)
        for (part, live) in s.livePaint {
            if live.mismatched {
                if live.deltaE >= (paintResult[part]?.deltaE ?? 0) {
                    paintResult[part] = (live.deltaE, live.textureRatio)
                }
            } else if paintResult[part] == nil, live.matchStreak >= 2 {
                paintResult[part] = (live.deltaE, live.textureRatio)
            }
        }
        let baseline = Self.gaugeBaseline(s.gaugeReadings)
        for part in CarPart.allCases where part.group == .body {
            guard paintResult[part] != nil || s.gaugeReadings[part] != nil || panels[part] != nil else { continue }
            var p = panels[part] ?? PanelAssessment(part: part)
            if let e = evidence[part] { p.photoIndex = e.photo; p.photoBox = CodableRect(e.box) }
            p.colourDeltaE = paintResult[part]?.deltaE
            p.textureRatio = paintResult[part]?.texture
            p.gaugeMicrons = s.gaugeReadings[part]
            p.paint = PaintAnalyzer.status(deltaE: p.colourDeltaE, texture: p.textureRatio, gauge: p.gaugeMicrons, baselineGauge: baseline)
            if let d = p.colourDeltaE { p.notes.append(String(format: "Colour vs comparable panels ΔE %.1f %@", d, d > 3 ? "(visible difference)" : "(matches)")) }
            if s.livePaint[part]?.mismatched == true { p.notes.append("Flagged during the walk-around from more than one angle.") }
            if let g = p.gaugeMicrons {
                p.notes.append(String(format: "Paint thickness %.0f µm%@", g, baseline.map { String(format: " (baseline %.0f µm)", $0) } ?? ""))
            } else if p.paint == .suspectedRepaint {
                p.notes.append("Camera only. Measure with a paint gauge to confirm before judging this panel.")
            }
            if p.gaugeMicrons == nil && p.colourDeltaE == nil && part.comparablePeers.isEmpty == false {
                p.notes.append("Seen, but no comparable panel was in the same view.")
            }
            if part.surface == .horizontal && p.gaugeMicrons == nil && p.colourDeltaE == nil {
                p.notes.append("Bonnet, roof and boot face the sky, so the camera cannot compare them with the sides. Use the gauge.")
            }
            switch p.paint {
            case .bodyFiller: p.replacement = .original; p.notes.append("Very thick paint → body filler under paint; panel was repaired after damage.")
            case .repainted where !p.damages.isEmpty: p.notes.append("Repainted and still shows damage.")
            default: break
            }
            // A bolt-on panel with a colour mismatch but an even re-spray thickness is typical of a replacement panel painted separately.
            if [.hood, .frontLeftFender, .frontRightFender, .frontLeftDoor, .frontRightDoor, .rearLeftDoor, .rearRightDoor, .trunk].contains(part),
               (p.colourDeltaE ?? 0) > 4, let g = p.gaugeMicrons, g > 150, g < 300 {
                p.replacement = .suspected
                p.notes.append("Bolt-on panel with even re-spray thickness and colour mismatch — likely replaced.")
            } else if p.replacement == .unknown, p.paint == .original { p.replacement = .original }
            if s.vehicle.condition == .new, p.paint != .original, p.paint != .notScanned {
                p.notes.append("NEW car: paintwork is not factory — ask about transport/PDI damage.")
            }
            panels[part] = p
        }
        report.panels = CarPart.allCases.compactMap { panels[$0] }

        // 2. Glass stamps
        await progress(0.45, "Reading glass manufacturer stamps…")
        var glass: [GlassAssessment] = []
        for (part, img) in s.glassPhotos {
            let stamp = TextScanner.glassStamp(in: TextScanner.recognize(img), modelYear: modelYear)
            glass.append(GlassAssessment(part: part, brand: stamp.brand, dateCode: stamp.raw.prefix(40).description, year: stamp.year))
        }
        let brandCounts = Dictionary(grouping: glass.compactMap(\.brand), by: { $0 }).mapValues(\.count)
        let majorityBrand = brandCounts.max { $0.value < $1.value }?.key
        for i in glass.indices {
            var g = glass[i]
            var flags: [String] = []
            let readableBrands = glass.compactMap(\.brand)
            if let b = g.brand, let m = majorityBrand, b != m, readableBrands.count >= 3 {
                flags.append("brand \(b) differs from the other windows (\(m))")
            } else if readableBrands.count == 2, Set(readableBrands).count == 2, g.part == .windshield, let b = g.brand,
                      let other = glass.first(where: { $0.part != .windshield && $0.brand != nil })?.brand {
                // Only two stamps read: with no majority, blame the windscreen, which is by far the most often replaced.
                flags.append("brand \(b) differs from the \(other) stamp on the other glass")
            }
            if let y = g.year, abs(y - modelYear) > 1 { flags.append("made in \(y) but car is \(modelYear)") }
            if g.brand == nil && g.year == nil { g.note = "Stamp not readable — retake closer, in shade." }
            else if flags.isEmpty { g.replacement = .original; g.note = "Matches factory glass." }
            else { g.replacement = flags.count > 1 ? .replaced : .suspected; g.note = "Replaced: " + flags.joined(separator: "; ") + "." }
            glass[i] = g
        }
        report.glass = glass.sorted { $0.part.rawValue < $1.part.rawValue }

        // 3. Tyres
        await progress(0.55, "Checking tyres (DOT age + tread)…")
        let tread = ImageClassifier(.treadWear)
        let positions: [CarPart] = [.wheelFrontLeft, .wheelFrontRight, .wheelRearLeft, .wheelRearRight]
        for pos in positions where s.tyreSidewallPhotos[pos] != nil || s.tyreTreadPhotos[pos] != nil || s.treadDepthMM[pos] != nil {
            var t = TyreAssessment(position: pos)
            if let img = s.tyreSidewallPhotos[pos], let dot = TextScanner.findTyreDOT(in: TextScanner.recognize(img)) {
                t.dotCode = dot.code
                t.weekYear = String(format: "Week %d / %d", dot.week, dot.year)
                var comps = DateComponents(); comps.weekOfYear = dot.week; comps.yearForWeekOfYear = dot.year; comps.weekday = 2
                if let made = Calendar(identifier: .iso8601).date(from: comps) {
                    t.ageYears = Date.now.timeIntervalSince(made) / (365.25 * 86400)
                }
            }
            if let img = s.tyreTreadPhotos[pos], tread.isReady {
                t.wearClass = tread.classify(img).max { $0.value < $1.value }?.key
            }
            t.treadDepthMM = s.treadDepthMM[pos]
            var notes: [String] = []
            t.score = ScoringEngine.tyreScore(t, isNewCar: s.vehicle.condition == .new, notes: &notes)
            t.notes = notes
            report.tyres.append(t)
        }

        // 4. Engine sound + OBD
        if !s.engineSamples.isEmpty {
            await progress(0.65, "Analysing engine sound…")
            report.engine = await EngineSoundAnalyzer(cylinders: s.vehicle.cylinders)
                .analyze(samples: s.engineSamples, sampleRate: s.engineSampleRate)
        }
        report.obd = s.obd

        // 5. Suspension
        report.suspension = s.suspension.map { corner, v in
            SuspensionAssessment(corner: corner, dampingRatio: v.zeta, oscillations: v.oscillations, score: SuspensionTester.score(zeta: v.zeta))
        }.sorted { $0.corner.rawValue < $1.corner.rawValue }

        // 6. Interior
        await progress(0.8, "Inspecting interior & dashboard…")
        if !s.interiorPhotos.isEmpty || s.dashboardPhoto != nil {
            var ia = InteriorAssessment()
            let clf = ImageClassifier(.interior)
            for img in s.interiorPhotos where clf.isReady {
                for (k, v) in clf.classify(img) { ia.labels[k] = max(ia.labels[k] ?? 0, v) }
            }
            if let dash = s.dashboardPhoto {
                ia.odometerOCR = TextScanner.odometer(in: TextScanner.recognize(dash))
                if clf.isReady, (clf.classify(dash)["dash_warning"] ?? 0) > 0.5 { ia.warningLights.append("Warning light(s) visible on the dashboard") }
            }
            let km = ia.odometerOCR ?? s.vehicle.mileageKm
            let age = max(1, Calendar.current.component(.year, from: .now) - modelYear)
            let wear = max(ia.labels["worn_steering"] ?? 0, ia.labels["worn_pedals"] ?? 0)
            if km > 0 {
                let perYear = km / age
                if let ecu = s.obd?.ecuOdometerKm, ecu > 0, abs(ecu - km) > max(1_000, km / 20) {
                    ia.mileageConsistency = "⚠︎ Dashboard shows \(km) km but the ECU stores \(ecu) km — odometer may have been changed."
                } else if wear > 0.6 && km < 60_000 {
                    ia.mileageConsistency = "⚠︎ Heavy wear for \(km) km — odometer may have been rolled back."
                } else if clf.isReady {
                    ia.mileageConsistency = "Wear consistent with \(km) km (~\(perYear) km/yr)."
                } else {
                    ia.mileageConsistency = "\(km) km (~\(perYear) km/yr). Wear model not installed, so wear was not compared."
                }
            }
            report.interior = ia
        }

        // 7. Scores, accident likelihood, verdict
        await progress(0.92, "Scoring…")
        ScoringEngine.finalize(&report, checklist: s.checklist)
        await progress(1, "Done")
        return report
    }

    /// Reference thickness for original paint on this car: the roof if measured (almost never repainted),
    /// otherwise the median of all readings (most panels on most cars are original).
    static func gaugeBaseline(_ readings: [CarPart: Double]) -> Double? {
        if let roof = readings[.roof] { return roof }
        let metal = readings.filter { $0.key.surface != .plastic }.map(\.value)
        return metal.count >= 3 ? metal.median : nil
    }

    /// Fraction of `a` that lies inside `b`.
    private func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, a.width * a.height > 0 else { return 0 }
        return (i.width * i.height) / (a.width * a.height)
    }
}

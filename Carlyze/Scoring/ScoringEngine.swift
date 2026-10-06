import Foundation

/// Converts measurements into 0–10 scores, accident likelihood and a plain-language verdict.
enum ScoringEngine {

    static func clamp(_ v: Double) -> Double { (max(0, min(10, v)) * 10).rounded() / 10 }

    // MARK: Tyres

    static func tyreScore(_ t: TyreAssessment, isNewCar: Bool, notes: inout [String]) -> Double {
        var s = 10.0
        if let d = t.treadDepthMM {
            // 8 mm new → 10, 1.6 mm legal minimum → 0
            s = min(s, (d - 1.6) / (8 - 1.6) * 10)
            if d < 3 { notes.append(String(format: "Tread %.1f mm — replace soon (wet grip drops below 3 mm).", d)) }
            else { notes.append(String(format: "Tread %.1f mm.", d)) }
        }
        switch t.wearClass ?? "" {
        case "worn": s = min(s, 3.5); notes.append("Tread looks worn.")
        case "fair": s = min(s, 7)
        case "uneven": s -= 1.5; notes.append("Uneven wear — check wheel alignment / suspension.")
        default: break
        }
        if let age = t.ageYears {
            notes.append(String(format: "Made %@ (%.1f yrs old).", t.weekYear ?? "", age))
            if isNewCar && age > 1.5 { s -= 1.5; notes.append("Old stock tyres fitted to a NEW car.") }
            if age > 10 { s -= 5; notes.append("Over 10 years — unsafe, replace.") }
            else if age > 6 { s -= 2.5; notes.append("Over 6 years — rubber hardening, plan replacement.") }
            else if age > 5 { s -= 1 }
        }
        if t.treadDepthMM == nil && t.wearClass == nil && t.ageYears == nil { notes.append("Not enough data scanned.") }
        return clamp(s)
    }

    // MARK: Final report

    static func finalize(_ r: inout InspectionReport, checklist: [String: Bool]) {
        var scores: [CategoryScore] = []

        // Exterior body & paint
        let body = r.panels.filter { $0.part.group == .body }
        let sawCar = !r.photoFiles.isEmpty || !body.isEmpty
        if !sawCar {
            r.scores = [CategoryScore(name: "Exterior body & paint", score: 0, summary: "No car in the photos.", verified: false)]
            r.overall = 0
            r.accident = .noSigns
            r.accidentEvidence = ["No car was detected. Retake the front, sides, and rear with the vehicle filling the frame."]
            r.verdict = "No car detected. This is not an inspection grade."
            return
        }
        var ext = 10.0
        var repaintCount = 0, fillerCount = 0, checkCount = 0
        for p in body {
            for d in p.damages { ext -= d.type.severityWeight * d.confidence }
            switch p.paint {
            case .suspectedRepaint: ext -= 0.3; checkCount += 1
            case .repainted: ext -= 1.0; repaintCount += 1
            case .bodyFiller: ext -= 1.8; fillerCount += 1
            default: break
            }
        }
        let gaugeUsed = body.contains { $0.gaugeMicrons != nil }
        var extSummary = body.isEmpty ? "Car detected. No panel defects measured." :
            "\(body.flatMap(\.damages).count) damage marks, \(repaintCount) repainted, \(fillerCount) with filler (gauge)."
        if checkCount > 0 { extSummary += " \(checkCount) panel(s) to check with a gauge." }
        scores.append(CategoryScore(name: "Exterior body & paint", score: clamp(ext), summary: extSummary,
            verified: gaugeUsed))

        // Glass
        if !r.glass.isEmpty {
            var g = 10.0
            g -= Double(r.glass.filter { $0.replacement == .replaced }.count) * 1.5
            g -= Double(r.glass.filter { $0.replacement == .suspected }.count) * 0.7
            g -= Double(r.panels.flatMap(\.damages).filter { $0.type == .glassShatter }.count) * 3
            scores.append(CategoryScore(name: "Glass (windscreen & windows)", score: clamp(g),
                summary: "\(r.glass.filter { $0.replacement != .original && $0.replacement != .unknown }.count) of \(r.glass.count) glass panels not original.", verified: true))
        }

        // Lights
        let lamps = r.panels.filter { $0.part.group == .lights }
        if !lamps.isEmpty {
            let broken = lamps.flatMap(\.damages).filter { $0.type == .lampBroken || $0.type == .crack }.count
            scores.append(CategoryScore(name: "Lights", score: clamp(10 - Double(broken) * 2.5),
                summary: broken == 0 ? "No cracked lamps detected." : "\(broken) cracked/broken lamp(s).", verified: true))
        }

        // Tyres
        if !r.tyres.isEmpty {
            let avg = r.tyres.map(\.score).reduce(0, +) / Double(r.tyres.count)
            let worst = r.tyres.min { $0.score < $1.score }!
            scores.append(CategoryScore(name: "Tyres", score: clamp(avg),
                summary: String(format: "Worst: %@ %.1f/10.", worst.position.displayName, worst.score), verified: true))
        }

        // Engine
        if r.engine != nil || r.obd?.connected == true {
            var e = 10.0
            var parts: [String] = []
            if let s = r.engine {
                e -= 4 * max(s.knockIndex, s.mlLabels["knock"] ?? 0)
                e -= 3 * max(s.misfireIndex, s.mlLabels["misfire"] ?? 0)
                if s.estimatedIdleRPM != nil { e -= 2.5 * (1 - s.idleStability) }
                e -= 1.5 * max(s.beltSquealIndex, s.mlLabels["belt_squeal"] ?? 0)
                e -= 1.5 * max(s.tappetTickIndex, s.mlLabels["tappet"] ?? 0)
                e -= 1.0 * (s.mlLabels["exhaust_leak"] ?? 0)
                parts.append(s.issues.isEmpty ? "Sound: smooth, no abnormal noises." : "Sound: \(s.issues.count) issue(s).")
            }
            if let o = r.obd, o.connected {
                e -= Double(o.troubleCodes.count) * 1.2
                if o.milOn { e -= 1.5 }
                if let lt = o.fuelTrimLongPct, abs(lt) > 10 { e -= 1; parts.append(String(format: "Long-term fuel trim %.0f%%.", lt)) }
                if let pending = o.pendingCodes, !pending.isEmpty {
                    e -= Double(pending.count) * 0.6
                    parts.append("Pending codes: \(pending.joined(separator: ", ")).")
                }
                if o.codesRecentlyCleared {
                    e -= 1.5
                    parts.append("Fault codes were cleared recently. Faults may be hidden; re-check after a few drives.")
                }
                parts.append(o.troubleCodes.isEmpty ? "ECU: no fault codes." : "ECU codes: \(o.troubleCodes.joined(separator: ", ")).")
            }
            if checklist[InspectionSession.checklistItems[7]] == true { e -= 1; parts.append("Oil leak reported.") }
            if checklist[InspectionSession.checklistItems[8]] == true { e -= 2; parts.append("Exhaust smoke reported.") }
            scores.append(CategoryScore(name: "Engine", score: clamp(e), summary: parts.joined(separator: " "), verified: true))
        }

        // Transmission (inspector input only)
        if checklist[InspectionSession.checklistItems[9]] != nil {
            let bad = checklist[InspectionSession.checklistItems[9]] == true
            scores.append(CategoryScore(name: "Gearbox / transmission", score: bad ? 5 : 9.5,
                summary: bad ? "Rough shifting or slipping reported on test drive." : "Smooth on test drive.", verified: false))
        }

        // Suspension
        if !r.suspension.isEmpty {
            let avg = r.suspension.map(\.score).reduce(0, +) / Double(r.suspension.count)
            let weak = r.suspension.filter { $0.score < 6.5 }.map(\.corner.displayName)
            scores.append(CategoryScore(name: "Suspension / shock absorbers", score: clamp(avg),
                summary: weak.isEmpty ? "All corners damp correctly." : "Weak damping at: \(weak.joined(separator: ", ")).", verified: true))
        }

        // Interior
        if let ia = r.interior {
            var s = 10.0
            let weights = ["seat_tear": 2.0, "stain": 1.0, "worn_steering": 1.0, "worn_pedals": 0.8, "headliner_sag": 1.0]
            for (k, w) in weights { s -= w * (ia.labels[k] ?? 0) }
            s -= Double(ia.warningLights.count) * 1.5
            if ia.mileageConsistency.hasPrefix("⚠︎") { s -= 2 }
            scores.append(CategoryScore(name: "Interior", score: clamp(s),
                summary: ([ia.mileageConsistency] + ia.warningLights).joined(separator: " "), verified: true))
        }

        // Structure / chassis (checklist)
        let structural = [0, 3, 4, 5, 6].map { InspectionSession.checklistItems[$0] }
        let structuralHits = structural.filter { checklist[$0] == true }
        if structural.contains(where: { checklist[$0] != nil }) {
            scores.append(CategoryScore(name: "Structure & safety", score: clamp(10 - Double(structuralHits.count) * 2.2),
                summary: structuralHits.isEmpty ? "No structural repair signs found by inspector." : structuralHits.joined(separator: "; "),
                verified: false))
        }

        r.scores = scores

        // Weighted overall
        let weights: [String: Double] = ["Engine": 3, "Exterior body & paint": 2, "Structure & safety": 2.5, "Suspension / shock absorbers": 1.5,
                                         "Tyres": 1, "Interior": 1.2, "Glass (windscreen & windows)": 0.8, "Lights": 0.4, "Gearbox / transmission": 2]
        let wsum = scores.map { weights[$0.name] ?? 1 }.reduce(0, +)
        r.overall = wsum > 0 ? clamp(scores.map { $0.score * (weights[$0.name] ?? 1) }.reduce(0, +) / wsum) : 0

        // Accident likelihood.
        // Verified evidence (gauge, glass stamps, inspector checks) can raise it to "major".
        // Camera-only colour differences add at most 2 points, so on their own they never go past "minor"
        // and never produce grade R: lighting alone must not brand a genuine car as an accident car.
        var points = 0.0, cameraPoints = 0.0
        var ev: [String] = []
        for p in body {
            switch p.paint {
            case .bodyFiller: points += 3; ev.append("\(p.part.displayName): body filler under paint (gauge)")
            case .repainted: points += 2; ev.append("\(p.part.displayName): repainted (gauge)")
            case .suspectedRepaint: cameraPoints += 0.6; ev.append("\(p.part.displayName): colour differs (camera only, confirm with gauge)")
            default: break
            }
            if p.replacement == .suspected || p.replacement == .replaced { points += 1.5; ev.append("\(p.part.displayName): likely replaced") }
            if p.damages.contains(where: { $0.type == .dent || $0.type == .crack }) { cameraPoints += 0.5 }
        }
        for g in r.glass where g.part == .windshield && g.replacement != .original && g.replacement != .unknown {
            points += 1; ev.append("Windscreen replaced (\(g.note))")
        }
        if repaintCount + fillerCount >= 6 { ev.append("Most panels repainted → likely full repaint (\"shower\"). Ask why.") }
        points += Double(structuralHits.count) * 2.5
        ev += structuralHits
        // Clustered repairs on one end are more telling than scattered ones. Only gauge-confirmed repairs count.
        let front: Set<CarPart> = [.hood, .frontBumper, .frontLeftFender, .frontRightFender]
        let rear: Set<CarPart> = [.trunk, .rearBumper, .rearLeftQuarter, .rearRightQuarter]
        let confirmed = Set(body.filter { $0.paint.isConfirmedRepair || $0.replacement == .suspected || $0.replacement == .replaced }.map(\.part))
        if confirmed.intersection(front).count >= 2 { points += 1.5; ev.append("Multiple front-end panels repaired → frontal impact pattern") }
        if confirmed.intersection(rear).count >= 2 { points += 1.5; ev.append("Multiple rear panels repaired → rear impact pattern") }
        let total = points + min(cameraPoints, 2)
        r.accident = total >= 8 ? .major : total >= 4 ? .moderate : total >= 1 ? .minor : .noSigns
        r.accidentVerified = points > 0
        r.accidentEvidence = ev

        // Verdict
        let rating: String
        switch r.overall {
        case 9...: rating = "Excellent"
        case 8..<9: rating = "Very good"
        case 7..<8: rating = "Good"
        case 5.5..<7: rating = "Fair — negotiate price"
        default: rating = "Poor — high risk"
        }
        var v = "\(rating) (\(String(format: "%.1f", r.overall))/10). \(r.accident.rawValue)."
        if r.vehicle.condition == .new && (repaintCount + fillerCount > 0 || r.accidentVerified == true) {
            v += " For a NEW car this is not acceptable — ask the dealer for a written explanation or a replacement vehicle."
        }
        if let o = r.obd, !o.troubleCodes.isEmpty { v += " ECU fault codes present." }
        if let o = r.obd, o.connected, o.codesRecentlyCleared { v += " ECU codes were cleared recently." }
        if checkCount > 0 && !gaugeUsed { v += " \(checkCount) panel(s) look different on camera; confirm with a paint gauge before deciding." }
        r.verdict = v
    }
}

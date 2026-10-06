import SwiftUI

/// Overall grade and the letter marks drawn on the body diagram.
/// Symbols follow the usual auction-sheet legend: A scratch, U dent, Y crack, W repair wave,
/// P repaint, S rust, X replace, XX replaced, G glass.
/// Carlyze adds C ("check"): the camera saw a colour difference that a paint gauge has not confirmed.
/// C marks cost one point and never count as a repair, so they can never make a car grade R.
enum JapanGradeSheet {
    struct Mark: Identifiable, Hashable {
        var id: String { "\(part.rawValue)-\(symbol)" }
        var part: CarPart
        var symbol: String
        var note: String
    }

    struct Result {
        var grade: String
        var meaning: String
        var interior: String
        var interiorMeaning: String
        var comment: String
        var marks: [Mark]
    }

    static func make(_ report: InspectionReport) -> Result {
        let sawCar = !report.photoFiles.isEmpty || report.panels.contains { $0.part.group == .body }
        if !sawCar {
            return Result(grade: "—", meaning: String(localized: "No car detected"), interior: "—",
                          interiorMeaning: String(localized: "Not scanned"),
                          comment: String(localized: "These photos do not show a car, so there is no inspection grade."), marks: [])
        }
        var marks: [Mark] = []
        for panel in report.panels where panel.part.group == .body || panel.part.group == .lights {
            let grouped = Dictionary(grouping: panel.damages, by: \.type)
            for (type, items) in grouped {
                guard let symbol = symbol(for: type, count: items.count, confidence: items.map(\.confidence).max() ?? 0.4) else { continue }
                marks.append(Mark(part: panel.part, symbol: symbol, note: "\(items.count)× \(type.displayName.lowercased())"))
            }
            switch panel.paint {
            case .suspectedRepaint:
                marks.append(Mark(part: panel.part, symbol: "C", note: "Colour differs on camera. Confirm with a paint gauge"))
            case .repainted:
                marks.append(Mark(part: panel.part, symbol: "P", note: "Repainted"))
            case .bodyFiller:
                marks.append(Mark(part: panel.part, symbol: "W3", note: "Body filler under the paint"))
            default: break
            }
            switch panel.replacement {
            case .replaced:
                marks.append(Mark(part: panel.part, symbol: "XX", note: "Panel replaced"))
            case .suspected:
                marks.append(Mark(part: panel.part, symbol: "X", note: "Panel likely replaced"))
            default: break
            }
        }
        for glass in report.glass where glass.replacement == .replaced || glass.replacement == .suspected {
            marks.append(Mark(part: glass.part, symbol: "G", note: glass.note.isEmpty ? "Glass not original" : glass.note))
        }

        let repaired = marks.contains { isRepair($0.symbol) }
        var grade = grade(points: marks.reduce(0) { $0 + points($1.symbol) }, report: report, repaired: repaired)
        var notes: [String] = []
        if let engine = report.engine, !engine.issues.isEmpty {
            let severe = engine.knockIndex > 0.45 || engine.misfireIndex > 0.45
            grade = drop(grade, by: severe ? 2 : 1)
            notes.append(severe ? "Engine knock or misfire" : "Engine noise")
        }
        if report.accident == .major {
            grade = "R"
            notes.append("Major repair pattern")
        } else if report.accident == .moderate && repaired {
            grade = "R"
        }

        let interior = interiorGrade(report.interior)
        let listed = marks.sorted { points($0.symbol) > points($1.symbol) }.prefix(6)
            .map { "\($0.symbol) \($0.part.displayName)" }
        var comment = listed.isEmpty ? String(localized: "No defect marks on the scanned panels.") : listed.joined(separator: " · ")
        if !notes.isEmpty { comment += " · " + notes.joined(separator: " · ") }

        return Result(grade: grade, meaning: meaning(grade), interior: interior.letter,
                      interiorMeaning: interior.meaning, comment: comment, marks: marks)
    }

    static func points(_ symbol: String) -> Int {
        if symbol == "XX" { return 5 }
        let digit = Int(symbol.dropFirst().prefix(1)) ?? 1
        switch symbol.prefix(1) {
        case "A": return digit
        case "U": return digit * 2
        case "Y": return 2 + digit * 2
        case "W": return 2 + digit * 2
        case "P": return 4
        case "S": return 3 + digit * 2
        case "G": return 3
        case "X": return 6
        case "C": return 1
        default: return 2
        }
    }

    static func color(_ symbol: String) -> Color {
        switch symbol.prefix(1) {
        case "A": return Color(red: 0.92, green: 0.72, blue: 0.08)
        case "U": return Color(red: 0.18, green: 0.42, blue: 0.92)
        case "Y": return Color(red: 0.86, green: 0.16, blue: 0.22)
        case "W": return Color(red: 0.52, green: 0.28, blue: 0.82)
        case "P": return Color(red: 0.90, green: 0.42, blue: 0.08)
        case "S": return Color(red: 0.55, green: 0.32, blue: 0.14)
        case "G": return Color(red: 0.05, green: 0.55, blue: 0.62)
        case "C": return Color(red: 0.98, green: 0.80, blue: 0.30)
        default: return Color(red: 0.75, green: 0.08, blue: 0.16) // X / XX
        }
    }

    static let legend: [(String, String)] = [
        ("A", "Scratch"), ("U", "Dent"), ("Y", "Crack"), ("W", "Repair"),
        ("P", "Repaint"), ("S", "Rust"), ("X", "Replace"), ("G", "Glass"), ("C", "Check paint")
    ]

    // MARK: - Grade scale

    private static func grade(points: Int, report: InspectionReport, repaired: Bool) -> String {
        if report.accident == .major { return "R" }
        if report.accident == .moderate && repaired { return "R" }
        if points == 0 && (report.vehicle.condition == .new || (report.vehicle.mileageKm > 0 && report.vehicle.mileageKm < 800)) {
            return "S"
        }
        let raw: String
        switch points {
        case 0: raw = "6"
        case 1...3: raw = "5"
        case 4...7: raw = "4.5"
        case 8...12: raw = "4"
        case 13...18: raw = "3.5"
        case 19...26: raw = "3"
        case 27...36: raw = "2"
        default: raw = "1"
        }
        if report.accident == .moderate {
            return worse(raw, "3.5")
        }
        return raw
    }

    private static func interiorGrade(_ interior: InteriorAssessment?) -> (letter: String, meaning: String) {
        guard let interior else { return ("—", String(localized: "Not photographed")) }
        if interior.mileageConsistency.hasPrefix("⚠︎") { return ("D", String(localized: "Wear does not match the mileage")) }
        if !interior.warningLights.isEmpty { return ("C", String(localized: "Warning light on the dash")) }
        let wear = ["seat_tear", "stain", "worn_steering", "worn_pedals", "headliner_sag"].compactMap { interior.labels[$0] }.max() ?? 0
        if interior.labels.isEmpty && wear == 0 { return ("B", String(localized: "Photographed, normal used cabin")) }
        switch wear {
        case ..<0.25: return ("A", String(localized: "Clean"))
        case ..<0.5: return ("B", String(localized: "Normal wear"))
        case ..<0.75: return ("C", String(localized: "Noticeable wear"))
        default: return ("D", String(localized: "Heavy wear or damage"))
        }
    }

    private static func isRepair(_ symbol: String) -> Bool {
        let head = symbol.prefix(1)
        return head == "W" || head == "P" || head == "X"
    }

    private static func symbol(for type: DamageType, count: Int, confidence: Double) -> String? {
        let size = (count >= 3 || confidence > 0.8) ? 3 : (count >= 2 || confidence > 0.55) ? 2 : 1
        switch type {
        case .scratch: return "A\(size)"
        case .dent: return "U\(size)"
        case .crack: return "Y\(size)"
        case .rust: return "S\(size)"
        case .glassShatter: return "G"
        case .lampBroken: return "X"
        case .tireFlat: return nil
        }
    }

    private static func meaning(_ grade: String) -> String {
        switch grade {
        case "S": String(localized: "As new")
        case "6": String(localized: "Nearly new")
        case "5": String(localized: "Excellent")
        case "4.5": String(localized: "Very good, small marks")
        case "4": String(localized: "Good used car")
        case "3.5": String(localized: "Average, visible defects")
        case "3": String(localized: "Below average")
        case "R": String(localized: "Repaired accident")
        case "2": String(localized: "Poor")
        case "1": String(localized: "Heavy damage")
        default: ""
        }
    }

    private static let ladder = ["S", "6", "5", "4.5", "4", "3.5", "3", "2", "1"]

    private static func drop(_ grade: String, by steps: Int) -> String {
        if grade == "R" { return "R" }
        guard let index = ladder.firstIndex(of: grade) else { return grade }
        return ladder[min(ladder.count - 1, index + steps)]
    }

    /// The worse of two grades on the auction scale. R is worse than a number.
    private static func worse(_ a: String, _ b: String) -> String {
        if a == "R" || b == "R" { return "R" }
        let ia = ladder.firstIndex(of: a) ?? 0
        let ib = ladder.firstIndex(of: b) ?? 0
        return ladder[max(ia, ib)]
    }
}

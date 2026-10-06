import Vision
import UIKit

/// On-device OCR (Vision) for the codes that reveal a car's history:
/// • VIN → model year, which every other date code is compared against
/// • Glass stamps → manufacturer + production year; a windscreen made by a different brand or
///   years later than the car means the glass was replaced (often after a front-end hit)
/// • Tyre DOT code → week/year of manufacture (tyre age)
/// • Odometer → mileage cross-check against wear
enum TextScanner {

    static func recognize(_ image: UIImage, fast: Bool = false) -> [String] {
        guard let cg = image.cgImage else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string.uppercased() }
    }

    // MARK: VIN

    static func findVIN(in lines: [String]) -> String? {
        let joined = lines.map { $0.replacingOccurrences(of: " ", with: "") }
        let regex = /[A-HJ-NPR-Z0-9]{17}/
        for l in joined {
            let fixed = l.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
                .replacingOccurrences(of: "Q", with: "0")
            if let m = fixed.firstMatch(of: regex) { return String(m.output) }
        }
        return nil
    }

    /// Japanese-market frame (chassis) number, used instead of a VIN on most JDM imports,
    /// e.g. "NZE141-1234567", "ZVW30-1234567", "GP5-3012345".
    static func findChassisNumber(in lines: [String]) -> String? {
        let regex = /\b([A-Z]{2,6}[0-9]{1,3}[A-Z]?)\s?-\s?([0-9]{5,7})\b/
        for l in lines {
            if let m = l.firstMatch(of: regex) { return "\(m.output.1)-\(m.output.2)" }
        }
        return nil
    }

    /// VIN if one is readable, otherwise a JDM chassis number.
    static func findVehicleID(in lines: [String]) -> String? {
        findVIN(in: lines) ?? findChassisNumber(in: lines)
    }

    /// 10th character of the VIN encodes model year (30-year cycle; assume the most recent).
    /// Only defined for 17-character VINs; chassis numbers carry no year, so the entered year is used.
    static func modelYear(fromVIN vin: String) -> Int? {
        guard vin.count == 17 else { return nil }
        let c = vin[vin.index(vin.startIndex, offsetBy: 9)]
        let codes = Array("ABCDEFGHJKLMNPRSTVWXY123456789")
        guard let idx = codes.firstIndex(of: c) else { return nil }
        let current = Calendar.current.component(.year, from: .now)
        var year = 1980 + idx
        while year + 30 <= current + 1 { year += 30 }
        return year
    }

    // MARK: Tyres

    /// DOT code ends with 4 digits WWYY (e.g. "2319" = week 23 of 2019).
    static func findTyreDOT(in lines: [String]) -> (code: String, week: Int, year: Int)? {
        let text = lines.joined(separator: " ")
        guard text.contains("DOT") else { return nil }
        let regex = /DOT[\sA-Z0-9]{2,16}?\s?(\d{2})(\d{2})(?!\d)/
        guard let m = text.firstMatch(of: regex),
              let w = Int(m.output.1), let y = Int(m.output.2), (1...53).contains(w) else { return nil }
        return (String(m.output.0), w, 2000 + y)
    }

    // MARK: Glass

    static let glassBrands = ["PILKINGTON", "AGC", "ASAHI", "SEKURIT", "SAINT-GOBAIN", "SAINT GOBAIN", "FUYAO", "GUARDIAN",
                              "XINYI", "CARLITE", "PPG", "VITRO", "SAFELITE", "NSG", "CENTRAL GLASS", "FYG", "SPLINTEX",
                              "BENSON", "SICURSIV", "SPECTRA", "LAMEX", "TEMPERLITE", "SEKURIT SAINT GOBAIN"]

    /// Returns (brand, year) from a glass bug/stamp. Year is decoded from the trailing digit
    /// in the stamp (e.g. "••• 8" or "18"), resolved to the decade closest to the car's model year.
    static func glassStamp(in lines: [String], modelYear: Int) -> (brand: String?, year: Int?, raw: String) {
        let text = lines.joined(separator: " ")
        let brand = glassBrands.first { text.contains($0) }
        var year: Int?
        // Tokenise; the date code is a lone 1–2 digit token, usually next to dots (months).
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "•" || $0 == "·" || $0 == "." }).map(String.init)
        let current = Calendar.current.component(.year, from: .now)
        for t in tokens where t.allSatisfy(\.isNumber) && (1...2).contains(t.count) {
            guard let v = Int(t) else { continue }
            if t.count == 2, (0...(current % 100)).contains(v) || v >= 80 {
                year = v >= 80 ? 1900 + v : 2000 + v
            } else if t.count == 1 {
                let candidates = [modelYear - 10, modelYear, modelYear + 10].map { ($0 / 10) * 10 + v }
                year = candidates.filter { $0 <= current }.min { abs($0 - modelYear) < abs($1 - modelYear) }
            }
            if year != nil { break }
        }
        return (brand, year, text)
    }

    // MARK: Odometer

    static func odometer(in lines: [String]) -> Int? {
        func numbers(_ l: String) -> [Int] {
            // Skip decimals such as trip meters ("123.4") and fuel economy.
            let cleaned = l.replacingOccurrences(of: #"\d+\.\d"#, with: " ", options: .regularExpression)
            return cleaned.matches(of: /(\d{1,3}(?:[,\s]\d{3})+|\d{3,7})/).map { String($0.output.0) }
                .compactMap { Int($0.filter(\.isNumber)) }
                .filter { $0 >= 10 && $0 < 2_000_000 }
        }
        // Prefer a number on a line that says ODO or km/mi, and not TRIP.
        let labelled = lines.filter { l in
            (l.contains("ODO") || l.contains("KM") || l.contains("MI")) && !l.contains("TRIP") && !l.contains("KM/H") && !l.contains("/L")
        }
        if let n = labelled.flatMap(numbers).max() { return n }
        return lines.filter { !$0.contains("TRIP") }.flatMap(numbers).max()
    }
}

import Foundation
import CoreGraphics

// MARK: - Vehicle

enum VehicleCondition: String, Codable, CaseIterable, Identifiable {
    case new = "New", used = "Used"
    var id: String { rawValue }
}

struct VehicleInfo: Codable, Hashable {
    var vin: String = ""
    var make: String = ""
    var model: String = ""
    var year: Int = Calendar.current.component(.year, from: .now)
    var mileageKm: Int = 0
    var cylinders: Int = 4
    var condition: VehicleCondition = .used

    var title: String {
        let t = "\(year) \(make) \(model)".trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Unnamed vehicle" : t
    }
}

// MARK: - Parts

enum PartGroup: String, Codable { case body, glass, lights, wheels, interior }

enum CarPart: String, Codable, CaseIterable, Identifiable {
    case frontBumper, rearBumper, hood, roof, trunk
    case frontLeftFender, frontRightFender, rearLeftQuarter, rearRightQuarter
    case frontLeftDoor, frontRightDoor, rearLeftDoor, rearRightDoor
    case leftMirror, rightMirror
    case windshield, rearWindow, frontLeftWindow, frontRightWindow, rearLeftWindow, rearRightWindow
    case headlightLeft, headlightRight, taillightLeft, taillightRight
    case wheelFrontLeft, wheelFrontRight, wheelRearLeft, wheelRearRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frontBumper: "Front bumper"
        case .rearBumper: "Rear bumper"
        case .hood: "Bonnet / hood"
        case .roof: "Roof"
        case .trunk: "Boot / trunk lid"
        case .frontLeftFender: "Front-left fender"
        case .frontRightFender: "Front-right fender"
        case .rearLeftQuarter: "Rear-left quarter panel"
        case .rearRightQuarter: "Rear-right quarter panel"
        case .frontLeftDoor: "Front-left door"
        case .frontRightDoor: "Front-right door"
        case .rearLeftDoor: "Rear-left door"
        case .rearRightDoor: "Rear-right door"
        case .leftMirror: "Left mirror"
        case .rightMirror: "Right mirror"
        case .windshield: "Windscreen (front)"
        case .rearWindow: "Rear screen"
        case .frontLeftWindow: "Front-left window"
        case .frontRightWindow: "Front-right window"
        case .rearLeftWindow: "Rear-left window"
        case .rearRightWindow: "Rear-right window"
        case .headlightLeft: "Left headlight"
        case .headlightRight: "Right headlight"
        case .taillightLeft: "Left tail-light"
        case .taillightRight: "Right tail-light"
        case .wheelFrontLeft: "Front-left tyre"
        case .wheelFrontRight: "Front-right tyre"
        case .wheelRearLeft: "Rear-left tyre"
        case .wheelRearRight: "Rear-right tyre"
        }
    }

    var group: PartGroup {
        switch self {
        case .windshield, .rearWindow, .frontLeftWindow, .frontRightWindow, .rearLeftWindow, .rearRightWindow: .glass
        case .headlightLeft, .headlightRight, .taillightLeft, .taillightRight: .lights
        case .wheelFrontLeft, .wheelFrontRight, .wheelRearLeft, .wheelRearRight: .wheels
        default: .body
        }
    }

    /// Painted panels that touch each other — used to compare colour/texture in the same frame.
    var neighbours: [CarPart] {
        switch self {
        case .hood: [.frontLeftFender, .frontRightFender, .frontBumper]
        case .frontLeftFender: [.hood, .frontLeftDoor, .frontBumper]
        case .frontRightFender: [.hood, .frontRightDoor, .frontBumper]
        case .frontLeftDoor: [.frontLeftFender, .rearLeftDoor]
        case .frontRightDoor: [.frontRightFender, .rearRightDoor]
        case .rearLeftDoor: [.frontLeftDoor, .rearLeftQuarter]
        case .rearRightDoor: [.frontRightDoor, .rearRightQuarter]
        case .rearLeftQuarter: [.rearLeftDoor, .trunk, .rearBumper]
        case .rearRightQuarter: [.rearRightDoor, .trunk, .rearBumper]
        case .trunk: [.rearLeftQuarter, .rearRightQuarter, .rearBumper]
        case .roof: [.hood, .trunk]
        case .frontBumper: [.frontLeftFender, .frontRightFender, .hood]
        case .rearBumper: [.rearLeftQuarter, .rearRightQuarter, .trunk]
        default: []
        }
    }

    /// Which way the panel faces. Light reflects differently off the bonnet (facing the sky) than off a door
    /// (facing sideways), so an original bonnet and fender can look different in the same photo.
    enum Surface { case horizontal, vertical, plastic, other }

    var surface: Surface {
        switch self {
        case .hood, .roof, .trunk: .horizontal
        case .frontBumper, .rearBumper, .leftMirror, .rightMirror: .plastic
        case .frontLeftFender, .frontRightFender, .rearLeftQuarter, .rearRightQuarter,
             .frontLeftDoor, .frontRightDoor, .rearLeftDoor, .rearRightDoor: .vertical
        default: .other
        }
    }

    /// The same panel on the other side of the car (both fenders are visible from the front, both quarters from the rear).
    var mirror: CarPart? {
        switch self {
        case .frontLeftFender: .frontRightFender
        case .frontRightFender: .frontLeftFender
        case .rearLeftQuarter: .rearRightQuarter
        case .rearRightQuarter: .rearLeftQuarter
        case .frontLeftDoor: .frontRightDoor
        case .frontRightDoor: .frontLeftDoor
        case .rearLeftDoor: .rearRightDoor
        case .rearRightDoor: .rearLeftDoor
        default: nil
        }
    }

    /// Panels whose colour can fairly be compared with this one in the same photo:
    /// touching neighbours that face the same way, plus the mirror panel.
    /// Plastic bumpers and mirrors are never compared (often a different shade from the factory).
    var comparablePeers: [CarPart] {
        guard surface == .vertical || surface == .horizontal else { return [] }
        var peers = neighbours.filter { $0.surface == surface }
        if let m = mirror { peers.append(m) }
        return peers
    }

    /// Label names produced by the CarParts detection model (see MLTraining/train_parts.py).
    init?(modelLabel: String) {
        let map: [String: CarPart] = [
            "front_bumper": .frontBumper, "back_bumper": .rearBumper, "hood": .hood, "roof": .roof,
            "trunk": .trunk, "front_left_fender": .frontLeftFender, "front_right_fender": .frontRightFender,
            "back_left_quarter": .rearLeftQuarter, "back_right_quarter": .rearRightQuarter,
            "front_left_door": .frontLeftDoor, "front_right_door": .frontRightDoor,
            "back_left_door": .rearLeftDoor, "back_right_door": .rearRightDoor,
            "left_mirror": .leftMirror, "right_mirror": .rightMirror,
            "front_glass": .windshield, "back_glass": .rearWindow,
            "front_left_window": .frontLeftWindow, "front_right_window": .frontRightWindow,
            "back_left_window": .rearLeftWindow, "back_right_window": .rearRightWindow,
            "front_left_light": .headlightLeft, "front_right_light": .headlightRight,
            "back_left_light": .taillightLeft, "back_right_light": .taillightRight,
            "front_left_wheel": .wheelFrontLeft, "front_right_wheel": .wheelFrontRight,
            "back_left_wheel": .wheelRearLeft, "back_right_wheel": .wheelRearRight,
            // Alias used by the public Ultralytics "carparts-seg" dataset. Its side-less labels
            // (front_door, back_door, front_light, back_light) are resolved in PanelLocator.part(for:box:side:).
            "tailgate": .trunk
        ]
        guard let p = map[modelLabel.lowercased()] else { return nil }
        self = p
    }
}

// MARK: - Findings

enum DamageType: String, Codable, CaseIterable {
    case scratch, dent, crack, glassShatter = "glass_shatter", lampBroken = "lamp_broken", tireFlat = "tire_flat", rust

    var displayName: String {
        switch self {
        case .scratch: "Scratch"
        case .dent: "Dent"
        case .crack: "Crack"
        case .glassShatter: "Broken / chipped glass"
        case .lampBroken: "Broken lamp"
        case .tireFlat: "Flat / low tyre"
        case .rust: "Rust / corrosion"
        }
    }
    var severityWeight: Double {
        switch self {
        case .scratch: 0.4
        case .rust: 0.9
        case .dent: 1.0
        case .crack, .lampBroken: 1.2
        case .glassShatter, .tireFlat: 1.5
        }
    }
}

struct CodableRect: Codable, Hashable {
    var x, y, w, h: Double
    init(_ r: CGRect) { x = r.minX; y = r.minY; w = r.width; h = r.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct DamageFinding: Identifiable, Codable, Hashable {
    var id = UUID()
    var part: CarPart?
    var type: DamageType
    var confidence: Double
    var box: CodableRect          // normalised, top-left origin
    var photoIndex: Int
}

enum PaintStatus: String, Codable {
    case original = "Original paint"
    case suspectedRepaint = "Possibly repainted"
    case repainted = "Repainted"
    case bodyFiller = "Repainted + body filler"
    case notScanned = "Not scanned"

    /// Wording used on screen. The raw values stay unchanged so saved reports still load.
    var label: String {
        switch self {
        case .original: "Genuine (original paint)"
        case .suspectedRepaint: "Check: colour differs (camera only)"
        case .repainted: "Repainted / shower (gauge)"
        case .bodyFiller: "Filler + paint (gauge)"
        case .notScanned: "Not scanned"
        }
    }

    /// Short label for tight spaces.
    var shortLabel: String {
        switch self {
        case .original: "Genuine"
        case .suspectedRepaint: "Check"
        case .repainted: "Repainted"
        case .bodyFiller: "Filler"
        case .notScanned: "—"
        }
    }

    /// True only when a paint thickness reading backs the status.
    var isConfirmedRepair: Bool { self == .repainted || self == .bodyFiller }
}

/// Which face of the car the phone is looking at during a live walk-around.
/// Order is clockwise from the front: front → right → rear → left.
enum ScanSide: String, CaseIterable, Identifiable, Hashable {
    case front, right, rear, left
    var id: String { rawValue }

    var title: String {
        switch self {
        case .front: "Front"
        case .right: "Right side"
        case .rear: "Rear"
        case .left: "Left side"
        }
    }

    var instruction: String {
        switch self {
        case .front: "Stand in front so the bonnet and both fenders fill the frame."
        case .right: "Move to the right side. Keep the whole side in frame, at door-handle height."
        case .rear: "Stand behind so the boot and both rear corners fill the frame."
        case .left: "Move to the left side. Keep the whole side in frame, at door-handle height."
        }
    }
}

/// Paint comparison accumulated while the camera is running.
struct LivePaintFinding: Hashable {
    var deltaE: Double
    var textureRatio: Double
    var mismatchStreak: Int = 0
    var matchStreak: Int = 0
    var mismatched: Bool = false
    /// Camera headings (degrees) at which this panel looked different. A reflection moves when
    /// you walk; a real colour difference stays, so a mismatch must be seen from two angles.
    var mismatchHeadings: [Double] = []

    /// Widest angle between two headings at which the mismatch was seen.
    var headingSpread: Double {
        var best = 0.0
        for (i, a) in mismatchHeadings.enumerated() {
            for b in mismatchHeadings[(i + 1)...] {
                var d = abs(a - b).truncatingRemainder(dividingBy: 360)
                if d > 180 { d = 360 - d }
                best = max(best, d)
            }
        }
        return best
    }
}

enum ReplacementStatus: String, Codable {
    case original = "Original"
    case suspected = "Possibly replaced"
    case replaced = "Replaced"
    case unknown = "Unknown"
}

struct PanelAssessment: Identifiable, Codable, Hashable {
    var id: CarPart { part }
    var part: CarPart
    var paint: PaintStatus = .notScanned
    var replacement: ReplacementStatus = .unknown
    var colourDeltaE: Double?        // CIEDE2000 vs neighbours (same frame)
    var textureRatio: Double?        // orange-peel texture vs neighbours
    var gaugeMicrons: Double?        // paint thickness gauge reading
    var photoIndex: Int?             // exterior photo that shows this panel best (evidence)
    var photoBox: CodableRect?       // where the panel is in that photo
    var damages: [DamageFinding] = []
    var notes: [String] = []
}

struct GlassAssessment: Identifiable, Codable, Hashable {
    var id: CarPart { part }
    var part: CarPart
    var brand: String?
    var dateCode: String?
    var year: Int?
    var replacement: ReplacementStatus = .unknown
    var note: String = ""
}

struct TyreAssessment: Identifiable, Codable, Hashable {
    var id: CarPart { position }
    var position: CarPart
    var dotCode: String?
    var weekYear: String?
    var ageYears: Double?
    var treadDepthMM: Double?
    var wearClass: String?            // from TreadWear classifier: good / fair / worn / uneven
    var score: Double = 0
    var notes: [String] = []
}

struct EngineSoundAssessment: Codable, Hashable {
    var durationSec: Double = 0
    var estimatedIdleRPM: Double?
    var idleStability: Double = 0     // 0…1 (1 = perfectly steady)
    var knockIndex: Double = 0        // 0…1
    var misfireIndex: Double = 0      // 0…1
    var beltSquealIndex: Double = 0   // 0…1
    var tappetTickIndex: Double = 0   // 0…1
    var mlLabels: [String: Double] = [:]
    var issues: [String] = []
}

struct OBDReport: Codable, Hashable {
    var connected = false
    var troubleCodes: [String] = []
    var coolantTempC: Double?
    var fuelTrimShortPct: Double?
    var fuelTrimLongPct: Double?
    var milOn: Bool = false
    // Added later: optional so older saved reports still decode.
    var pendingCodes: [String]?
    var monitorsNotReady: Int?            // emission self-tests not finished (high right after codes are cleared)
    var warmupsSinceCleared: Int?         // PID 0x30
    var distanceSinceClearedKm: Int?      // PID 0x31
    var ecuOdometerKm: Int?               // PID 0xA6 (newer cars only)

    /// Sellers sometimes clear fault codes just before a viewing. Fresh self-tests give it away.
    var codesRecentlyCleared: Bool {
        if let d = distanceSinceClearedKm, d < 150 { return true }
        if let w = warmupsSinceCleared, w < 5 { return true }
        if let m = monitorsNotReady, m >= 3 { return true }
        return false
    }
}

struct SuspensionAssessment: Identifiable, Codable, Hashable {
    var id: CarPart { corner }
    var corner: CarPart               // uses wheel positions
    var dampingRatio: Double          // ζ; good shocks ≈ 0.25–0.5
    var oscillations: Int
    var score: Double
}

struct InteriorAssessment: Codable, Hashable {
    var labels: [String: Double] = [:]  // e.g. seat_tear, stain, worn_steering, dash_warning_light
    var odometerOCR: Int?
    var warningLights: [String] = []
    var mileageConsistency: String = "Not checked"
    var notes: [String] = []
}

struct CategoryScore: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var score: Double                 // 0…10
    var summary: String
    var verified: Bool                // backed by a scan/measurement, not just user input
}

enum AccidentLikelihood: String, Codable {
    case noSigns = "No accident signs"
    case minor = "Minor cosmetic repair likely"
    case moderate = "Accident repair likely"
    case major = "Major accident repair likely"
}

// MARK: - Report

struct InspectionReport: Identifiable, Codable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var vehicle = VehicleInfo()
    var photoFiles: [String] = []
    /// Damage the model found that could not be tied to a panel (optional: older reports lack it).
    var unassignedDamages: [DamageFinding]?
    var panels: [PanelAssessment] = []
    var glass: [GlassAssessment] = []
    var tyres: [TyreAssessment] = []
    var engine: EngineSoundAssessment?
    var obd: OBDReport?
    var suspension: [SuspensionAssessment] = []
    var interior: InteriorAssessment?
    var scores: [CategoryScore] = []
    var overall: Double = 0
    var accident: AccidentLikelihood = .noSigns
    var accidentEvidence: [String] = []
    /// True when the accident finding rests on a gauge, glass stamp or inspector check, not only on camera colour.
    var accidentVerified: Bool?
    var verdict: String = ""
    var modelsUsed: [String] = []
}

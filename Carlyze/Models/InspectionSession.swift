import UIKit
import Observation

/// Everything the user captures during an inspection, before analysis.
@Observable
final class InspectionSession: Identifiable {
    let id = UUID()
    var vehicle = VehicleInfo()

    // Exterior walk-around. The live scan fills this with one frame per side.
    var exteriorPhotos: [UIImage] = []
    /// Which side of the car each exterior photo shows (index into `exteriorPhotos`), when known.
    /// Lets the analyser locate panels by framing when no parts model is installed.
    var exteriorPhotoSides: [Int: ScanSide] = [:]
    /// Panels compared during the live walk-around. Survives leaving the camera screen.
    var livePaint: [CarPart: LivePaintFinding] = [:]
    var coveredExteriorSides: Set<ScanSide> = []

    // Close-ups
    var glassPhotos: [CarPart: UIImage] = [:]          // photo of each glass stamp ("bug")
    var tyreSidewallPhotos: [CarPart: UIImage] = [:]   // DOT code
    var tyreTreadPhotos: [CarPart: UIImage] = [:]      // tread surface
    var treadDepthMM: [CarPart: Double] = [:]          // optional gauge / coin test entry

    // Interior
    var interiorPhotos: [UIImage] = []
    var dashboardPhoto: UIImage?                       // ignition ON, engine running (warning lights + odometer)

    // Engine
    var engineSamples: [Float] = []
    var engineSampleRate: Double = 44_100
    var obd: OBDReport?

    // Suspension bounce test
    var suspension: [CarPart: (zeta: Double, oscillations: Int)] = [:]

    // Paint thickness gauge (µm), optional — confirms repaint findings
    var gaugeReadings: [CarPart: Double] = [:]

    // Inspector checklist (things a camera can't see reliably)
    var checklist: [String: Bool] = [:]

    static let checklistItems: [String] = [
        "Paint cracked / tool marks on hood, fender or door hinge bolts",
        "Factory stickers missing from door jambs or hood underside",
        "Overspray on rubber seals, trims or plastic parts",
        "Uneven panel gaps (e.g. hood vs fender, door vs quarter panel)",
        "Welding marks / wavy metal in boot floor or engine bay",
        "Chassis rails (engine bay) bent, rippled or re-welded",
        "Airbag light stays on / SRS covers not factory",
        "Oil leak visible under engine or gearbox",
        "Blue / white smoke from exhaust on revving",
        "Gear shifts rough or clutch slips on test drive"
    ]

    /// Adds an exterior photo and remembers which side it shows.
    func addExteriorPhoto(_ image: UIImage, side: ScanSide?) {
        exteriorPhotos.append(image)
        if let side { exteriorPhotoSides[exteriorPhotos.count - 1] = side }
    }

    /// Folds one live frame into the paint record. Returns panels that just crossed the confirmation threshold.
    /// `heading` is the camera direction in degrees (nil when unknown). With a heading, a mismatch must be seen
    /// from two angles at least `minSpread` degrees apart, so a moving reflection is not reported as a repaint.
    @discardableResult
    func recordLivePaint(_ regions: [LivePaintScanner.Region], heading: Double? = nil, minSpread: Double = 12) -> [CarPart] {
        var paint = livePaint
        var newly: [CarPart] = []
        for region in regions {
            var finding = paint[region.part] ?? LivePaintFinding(deltaE: region.deltaE, textureRatio: region.textureRatio)
            let wasMismatch = finding.mismatched
            if region.mismatched {
                finding.mismatchStreak += 1
                finding.matchStreak = 0
                finding.deltaE = max(finding.deltaE, region.deltaE)
                finding.textureRatio = region.textureRatio
                if let heading {
                    finding.mismatchHeadings.append(heading)
                    if finding.mismatchHeadings.count > 24 { finding.mismatchHeadings.removeFirst() }
                }
                let angleOK = heading == nil || finding.headingSpread >= minSpread
                if finding.mismatchStreak >= 3 && angleOK { finding.mismatched = true }
            } else if !finding.mismatched {
                finding.matchStreak += 1
                finding.mismatchStreak = 0
                finding.deltaE = region.deltaE
                finding.textureRatio = region.textureRatio
            }
            if !wasMismatch && finding.mismatched { newly.append(region.part) }
            paint[region.part] = finding
        }
        livePaint = paint
        return newly
    }

    var completedSteps: Int {
        [ !vehicle.make.isEmpty, !exteriorPhotos.isEmpty || !livePaint.isEmpty, !glassPhotos.isEmpty,
          !tyreSidewallPhotos.isEmpty || !tyreTreadPhotos.isEmpty, !interiorPhotos.isEmpty || dashboardPhoto != nil,
          !engineSamples.isEmpty, !suspension.isEmpty, !gaugeReadings.isEmpty, obd?.connected == true ].filter { $0 }.count
    }
}

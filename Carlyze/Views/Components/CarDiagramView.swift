import SwiftUI

/// Top-down schematic of the car; each panel is coloured by its paint/damage status and each tyre by its score.
struct CarDiagramView: View {
    let panels: [PanelAssessment]
    let glass: [GlassAssessment]
    let tyres: [TyreAssessment]
    var marks: [JapanGradeSheet.Mark] = []
    @Binding var selected: CarPart?

    // Unit layout in a 1 × 2 box (front at top).
    static let layout: [CarPart: CGRect] = [
        .frontBumper: .init(x: 0.14, y: 0.00, width: 0.72, height: 0.06),
        .hood: .init(x: 0.19, y: 0.07, width: 0.62, height: 0.22),
        .frontLeftFender: .init(x: 0.06, y: 0.07, width: 0.12, height: 0.22),
        .frontRightFender: .init(x: 0.82, y: 0.07, width: 0.12, height: 0.22),
        .windshield: .init(x: 0.21, y: 0.30, width: 0.58, height: 0.09),
        .roof: .init(x: 0.21, y: 0.40, width: 0.58, height: 0.26),
        .rearWindow: .init(x: 0.21, y: 0.67, width: 0.58, height: 0.07),
        .trunk: .init(x: 0.19, y: 0.75, width: 0.62, height: 0.17),
        .rearBumper: .init(x: 0.14, y: 0.93, width: 0.72, height: 0.06),
        .frontLeftDoor: .init(x: 0.06, y: 0.30, width: 0.14, height: 0.20),
        .frontRightDoor: .init(x: 0.80, y: 0.30, width: 0.14, height: 0.20),
        .rearLeftDoor: .init(x: 0.06, y: 0.51, width: 0.14, height: 0.18),
        .rearRightDoor: .init(x: 0.80, y: 0.51, width: 0.14, height: 0.18),
        .rearLeftQuarter: .init(x: 0.06, y: 0.70, width: 0.12, height: 0.22),
        .rearRightQuarter: .init(x: 0.82, y: 0.70, width: 0.12, height: 0.22),
        .wheelFrontLeft: .init(x: 0.0, y: 0.11, width: 0.06, height: 0.13),
        .wheelFrontRight: .init(x: 0.94, y: 0.11, width: 0.06, height: 0.13),
        .wheelRearLeft: .init(x: 0.0, y: 0.74, width: 0.06, height: 0.13),
        .wheelRearRight: .init(x: 0.94, y: 0.74, width: 0.06, height: 0.13)
    ]

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height / 2)
            let origin = CGPoint(x: (geo.size.width - w) / 2, y: 0)
            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.layout.keys), id: \.self) { part in
                    let r = Self.layout[part]!
                    RoundedRectangle(cornerRadius: part.group == .wheels ? 3 : 6, style: .continuous)
                        .fill(fill(for: part))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == part ? Color.white : Color.black.opacity(0.35), lineWidth: selected == part ? 2 : 1))
                        .overlay(alignment: .center) {
                            if let symbol = primaryMark(part)?.symbol {
                                Text(symbol)
                                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(.black.opacity(0.72), in: Capsule())
                                    .foregroundStyle(.white)
                            } else if let n = damageCount(part), n > 0 {
                                Text("\(n)").font(.caption2.bold()).padding(4).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white)
                            }
                        }
                        .frame(width: r.width * w, height: r.height * w * 2)
                        .offset(x: origin.x + r.minX * w, y: r.minY * w * 2)
                        .onTapGesture { selected = part }
                        .accessibilityLabel(part.displayName)
                }
            }
        }
        .aspectRatio(0.5, contentMode: .fit)
    }

    private func damageCount(_ p: CarPart) -> Int? { panels.first { $0.part == p }?.damages.count }

    private func primaryMark(_ part: CarPart) -> JapanGradeSheet.Mark? {
        marks.filter { $0.part == part }.max { JapanGradeSheet.points($0.symbol) < JapanGradeSheet.points($1.symbol) }
    }

    private func fill(for part: CarPart) -> Color {
        if let symbol = primaryMark(part)?.symbol { return JapanGradeSheet.color(symbol) }
        switch part.group {
        case .wheels:
            guard let t = tyres.first(where: { $0.position == part }) else { return .gray.opacity(0.35) }
            return Theme.color(for: t.score)
        case .glass:
            guard let g = glass.first(where: { $0.part == part }) else { return Color(white: 0.35).opacity(0.5) }
            switch g.replacement {
            case .original: return Theme.accent2.opacity(0.7)
            case .suspected: return Theme.warn
            case .replaced: return Color.orange
            case .unknown: return Color(white: 0.4)
            }
        default:
            guard let p = panels.first(where: { $0.part == part }) else { return .gray.opacity(0.3) }
            if p.replacement == .suspected || p.replacement == .replaced { return .purple }
            return Theme.color(for: p.paint)
        }
    }
}

struct DiagramLegend: View {
    var body: some View {
        let items: [(String, Color)] = [("Original", Theme.accent), ("Check (camera)", Theme.warn), ("Repainted (gauge)", .orange),
                                        ("Filler (gauge)", Theme.bad), ("Likely replaced", .purple), ("Not scanned", .gray.opacity(0.4))]
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(item.1).frame(width: 14, height: 14)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

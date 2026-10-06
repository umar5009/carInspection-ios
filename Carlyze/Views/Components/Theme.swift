import SwiftUI

enum Theme {
    static let bg = Color("LaunchBackground")                 // #0A1428 navy (asset catalog)
    static let card = Color(red: 0.08, green: 0.13, blue: 0.24)
    static let accent = Color(red: 0.0, green: 0.88, blue: 0.72)  // teal-mint scan colour
    static let accent2 = Color(red: 0.23, green: 0.56, blue: 1.0)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)

    static func color(for score: Double) -> Color {
        switch score {
        case 8.5...: accent
        case 7..<8.5: Color(red: 0.55, green: 0.85, blue: 0.35)
        case 5..<7: warn
        default: bad
        }
    }

    static func color(for paint: PaintStatus) -> Color {
        switch paint {
        case .original: accent
        case .suspectedRepaint: warn
        case .repainted: Color.orange
        case .bodyFiller: bad
        case .notScanned: .gray.opacity(0.4)
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: icon ?? "circle").font(.headline).foregroundStyle(.white)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.06)))
    }
}

struct ScoreRing: View {
    let score: Double
    var size: CGFloat = 140
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: size * 0.09)
            Circle().trim(from: 0, to: score / 10)
                .stroke(AngularGradient(colors: [Theme.accent2, Theme.color(for: score)], center: .center),
                        style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(String(format: "%.1f", score)).font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                Text("/ 10").font(.system(size: size * 0.1, weight: .medium)).foregroundStyle(.secondary)
            }.foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct ScoreBar: View {
    let item: CategoryScore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).font(.subheadline.weight(.semibold))
                if item.verified {
                    Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.accent)
                        .accessibilityLabel("Verified by scan")
                } else {
                    Text(item.name == "Exterior body & paint" ? "camera" : "inspector").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                Spacer()
                Text(String(format: "%.1f / 10", item.score)).font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(Theme.color(for: item.score))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(Theme.color(for: item.score)).frame(width: g.size.width * item.score / 10)
                }
            }.frame(height: 8)
            Text(item.summary).font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String = "viewfinder"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(Color.black.opacity(0.85))
        }
    }
}

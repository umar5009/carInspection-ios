import SwiftUI

@main
struct CarlyzeApp: App {
    @State private var showSplash = true
    @State private var store = ReportStore.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView()
                    .environment(store)
                if showSplash {
                    SplashView { withAnimation(.easeOut(duration: 0.35)) { showSplash = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
    }
}

/// Animated continuation of the static launch screen (same background + logo, so the hand-off is seamless):
/// a scan line sweeps over the car, corner brackets lock on, then the wordmark appears.
struct SplashView: View {
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    var onFinish: () -> Void
    @State private var sweep: CGFloat = -1
    @State private var locked = false
    @State private var showTitle = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .center, startRadius: 10, endRadius: 320)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                ZStack {
                    Image("LaunchLogo").resizable().scaledToFit().frame(width: 200, height: 200)
                    // Scan line
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Theme.accent.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 26)
                            .offset(y: (sweep + 1) / 2 * (g.size.height - 26))
                            .blendMode(.screen)
                    }
                    .frame(width: 200, height: 200)
                    .mask(RoundedRectangle(cornerRadius: 40))
                    .opacity(locked ? 0 : 1)
                    // Lock-on brackets
                    Brackets().stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: locked ? 232 : 290, height: locked ? 232 : 290)
                        .opacity(locked ? 1 : 0)
                }
                VStack(spacing: 6) {
                    Text("Carlyze").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    Text("AI Car Inspection").font(.headline).foregroundStyle(Theme.accent)
                }
                .opacity(showTitle ? 1 : 0)
                .offset(y: showTitle ? 0 : 12)
            }
        }
        .task {
            withAnimation(.easeInOut(duration: 0.9)) { sweep = 1 }
            try? await Task.sleep(for: .milliseconds(850))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { locked = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) { showTitle = true }
            try? await Task.sleep(for: .milliseconds(1000))
            onFinish()
        }
    }
}

struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        let l = r.width * 0.2
        var p = Path()
        for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: c.x, y: c.y + dy * l)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x + dx * l, y: c.y))
        }
        return p
    }
}


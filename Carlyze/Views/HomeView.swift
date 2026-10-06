import SwiftUI

struct HomeView: View {
    @Environment(ReportStore.self) private var store
    @State private var session: InspectionSession?
    @State private var fullSession: InspectionSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    PrimaryButton(title: "Quick guided inspection", icon: "waveform.and.mic") { session = InspectionSession() }
                    Button { fullSession = InspectionSession() } label: {
                        Label("Full inspection: AR paint scan, gauge, OBD", systemImage: "arkit")
                            .font(.headline)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.6)))
                            .foregroundStyle(Theme.accent)
                    }

                    HStack(spacing: 12) {
                        feature("camera.viewfinder", "AR paint scan + gauge")
                        feature("waveform", "Engine sound AI")
                        feature("gauge.with.dots.needle.67percent", "Suspension test")
                    }

                    Text("Reports").font(.title3.bold()).foregroundStyle(.white).padding(.top, 8)
                    if store.reports.isEmpty {
                        Card { Text("No inspections yet. Your reports will appear here.").foregroundStyle(.secondary) }
                    }
                    ForEach(store.reports) { r in
                        NavigationLink(value: r) { ReportRow(report: r) }
                            .contextMenu { Button("Delete", role: .destructive) { store.delete(r) } }
                    }
                }
                .padding()
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Carlyze")
            .navigationDestination(for: InspectionReport.self) { ReportView(report: $0) }
            .fullScreenCover(item: $session) { s in
                GuidedInspectionView(session: s) { session = nil }
            }
            .fullScreenCover(item: $fullSession) { s in
                InspectionFlowView(session: s) { fullSession = nil }
            }
        }
    }

    private var hero: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Know the car before you buy it.").font(.title2.bold()).foregroundStyle(.white)
                Text("Quick: follow the voice and get a grade sheet. Full: walk around with AR, confirm paint with a gauge, read the ECU.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func feature(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent)
            Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ReportRow: View {
    let report: InspectionReport
    var body: some View {
        HStack(spacing: 14) {
            let sheet = JapanGradeSheet.make(report)
            Text(sheet.grade)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .frame(width: 54, height: 54)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.vehicle.title).font(.headline).foregroundStyle(.white)
                Text("\(sheet.meaning) · interior \(sheet.interior)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(report.accident.rawValue).font(.caption.weight(.semibold))
                    .foregroundStyle(report.accident == .noSigns ? Theme.accent : Theme.warn)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

import SwiftUI

/// Renders the report as a vector, multi-page A4 PDF (same view as on screen, so they never diverge).
@MainActor
enum PDFExporter {
    static func export(_ report: InspectionReport) -> URL? {
        let pageSize = CGSize(width: 595, height: 842)   // A4 @ 72 dpi
        let content = VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image("LaunchLogo").resizable().frame(width: 34, height: 34)
                Text("Carlyze Inspection Report").font(.title2.bold()).foregroundStyle(.white)
                Spacer()
                Text("ID \(report.id.uuidString.prefix(8))").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ReportContent(report: report, selected: .constant(nil), interactive: false)
        }
        .padding(24)
        .frame(width: pageSize.width)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: pageSize.width, height: nil)

        let safeName = report.vehicle.title.replacingOccurrences(of: " ", with: "_")
        let url = FileManager.default.temporaryDirectory.appending(path: "Carlyze_\(safeName)_\(report.id.uuidString.prefix(6)).pdf")
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: pageSize)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            let pages = max(1, Int(ceil(size.height / pageSize.height)))
            for i in 0..<pages {
                pdf.beginPDFPage(nil)
                pdf.setFillColor(UIColor(Theme.bg).cgColor)
                pdf.fill(box)
                pdf.saveGState()
                // PDF origin is bottom-left; shift so page i shows the i-th slice from the top.
                pdf.translateBy(x: 0, y: -(size.height - CGFloat(i + 1) * pageSize.height))
                draw(pdf)
                pdf.restoreGState()
                pdf.endPDFPage()
            }
            pdf.closePDF()
            ok = true
        }
        return ok ? url : nil
    }
}

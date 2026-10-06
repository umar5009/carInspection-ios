import SwiftUI

/// Grade sheet: overall grade, interior grade, and a body diagram with defect marks.
/// Labels follow the phone language.
struct AuctionSheetView: View {
    let report: InspectionReport
    private var sheet: JapanGradeSheet.Result { JapanGradeSheet.make(report) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Inspection sheet").font(.caption.weight(.bold)).tracking(1.1)
                Spacer()
                Text(report.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(Color.black.opacity(0.55))

            HStack(alignment: .center, spacing: 8) {
                gradeBlock(title: "Grade", value: sheet.grade, caption: sheet.meaning)
                JapanSheetDiagram(marks: sheet.marks)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                gradeBlock(title: "Interior", value: sheet.interior, caption: sheet.interiorMeaning)
            }

            Text(report.vehicle.title).font(.subheadline.weight(.semibold))
            Text(sheet.comment).font(.caption).foregroundStyle(Color.black.opacity(0.7)).fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(JapanGradeSheet.legend, id: \.0) { item in
                    HStack(spacing: 4) {
                        Text(item.0)
                            .font(.caption2.bold())
                            .frame(width: 16, height: 16)
                            .background(JapanGradeSheet.color(item.0), in: Circle())
                        Text(LocalizedStringKey(item.1)).font(.caption2)
                    }
                    .foregroundStyle(.black)
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.97, green: 0.95, blue: 0.90))
        .foregroundStyle(Color(red: 0.09, green: 0.11, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.black.opacity(0.12), lineWidth: 1))
    }

    private func gradeBlock(title: LocalizedStringKey, value: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(Color.black.opacity(0.5))
            Text(value)
                .font(.system(size: value.count > 2 ? 28 : 40, weight: .black, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(value == "R" || value == "1" || value == "2" ? Color(red: 0.7, green: 0.1, blue: 0.12) : .black)
            Text(caption)
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.black.opacity(0.55))
                .frame(width: 72)
        }
        .frame(width: 78)
    }
}

/// Top-down car on the paper sheet. Clean panels stay blank; defected panels take the mark colour and letter.
struct JapanSheetDiagram: View {
    let marks: [JapanGradeSheet.Mark]

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height / 2)
            let origin = CGPoint(x: (geo.size.width - w) / 2, y: 0)
            ZStack(alignment: .topLeading) {
                ForEach(Array(CarDiagramView.layout.keys), id: \.self) { part in
                    let rect = CarDiagramView.layout[part]!
                    let partMarks = marks.filter { $0.part == part }.sorted { JapanGradeSheet.points($0.symbol) > JapanGradeSheet.points($1.symbol) }
                    let symbol = partMarks.first?.symbol
                    RoundedRectangle(cornerRadius: part.group == .wheels ? 2 : 4, style: .continuous)
                        .fill(symbol.map { JapanGradeSheet.color($0).opacity(0.92) } ?? Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.55), lineWidth: 1))
                        .overlay {
                            if let symbol {
                                Text(symbol)
                                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.black)
                                    .minimumScaleFactor(0.5)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: rect.width * w, height: rect.height * w * 2)
                        .offset(x: origin.x + rect.minX * w, y: rect.minY * w * 2)
                }
            }
        }
    }
}

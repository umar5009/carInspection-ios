import UIKit
import Observation

/// Saves reports as JSON + photos in Application Support.
@Observable
final class ReportStore {
    static let shared = ReportStore()
    private(set) var reports: [InspectionReport] = []

    private var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Inspections")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() { load() }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        reports = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(InspectionReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ r: InspectionReport) {
        let url = dir.appending(path: "\(r.id).json")
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: url, options: .atomic) }
        load()
    }

    func delete(_ r: InspectionReport) {
        try? FileManager.default.removeItem(at: dir.appending(path: "\(r.id).json"))
        r.photoFiles.forEach { try? FileManager.default.removeItem(at: dir.appending(path: $0)) }
        load()
    }

    func savePhotos(_ images: [UIImage], for id: UUID) -> [String] {
        images.prefix(12).enumerated().compactMap { i, img in
            let name = "\(id)-\(i).jpg"
            guard let d = img.normalized(maxSide: 1200).jpegData(compressionQuality: 0.75) else { return nil }
            try? d.write(to: dir.appending(path: name))
            return name
        }
    }

    func photo(_ name: String) -> UIImage? { UIImage(contentsOfFile: dir.appending(path: name).path) }
}

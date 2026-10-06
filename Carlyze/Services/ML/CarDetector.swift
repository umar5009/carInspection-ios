import UIKit
import Vision

/// On-device check that a photo actually shows a car (or the car part that step asks for).
/// Uses the system image classifier, so headphones, rooms, and other objects are rejected.
enum CarDetector {
    /// Passenger vehicles in Apple's Vision taxonomy. Exact identifiers only,
    /// so "car_seat", "vehicle_toy", and "cableway" do not count.
    static let vehicles: Set<String> = [
        "car", "automobile", "suv", "sportscar", "truck", "van", "wagon",
        "jeep", "convertible", "limousine", "police_car", "engine_vehicle", "vehicle"
    ]

    static func sees(_ image: UIImage, labels: Set<String>) -> Bool {
        guard let cg = image.cgImage else { return false }
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        let handler = VNImageRequestHandler(cgImage: cg, orientation: image.cgOrientation)
        guard (try? handler.perform([request])) != nil else { return false }
        return (request.results ?? []).contains { observation in
            labels.contains(observation.identifier)
                && observation.hasMinimumRecall(0, forPrecision: 0.5)
        }
    }
}

enum CaptureSubject {
    case vehicle, vin, glass, tyre, cabin

    var rejection: String {
        switch self {
        case .vehicle: "No car in this photo. Fill the frame with the vehicle and tap again."
        case .vin: "No VIN or car in this photo. Frame the VIN plate and tap again."
        case .glass: "No car or windscreen stamp in this photo. Move closer and tap again."
        case .tyre: "No tyre in this photo. Fill the frame with the tyre and tap again."
        case .cabin: "This doesn't look like the car interior. Frame the seat or dashboard and tap again."
        }
    }

    func matches(_ image: UIImage) -> Bool {
        switch self {
        case .vehicle:
            return CarDetector.sees(image, labels: CarDetector.vehicles)
        case .vin:
            if CarDetector.sees(image, labels: CarDetector.vehicles.union(["dashboard"])) { return true }
            return TextScanner.findVehicleID(in: TextScanner.recognize(image, fast: true)) != nil
        case .glass:
            if CarDetector.sees(image, labels: CarDetector.vehicles) { return true }
            let stamp = TextScanner.glassStamp(in: TextScanner.recognize(image, fast: true), modelYear: 2020)
            return stamp.brand != nil
        case .tyre:
            return CarDetector.sees(image, labels: CarDetector.vehicles.union(["tire", "wheel"]))
        case .cabin:
            return CarDetector.sees(image, labels: CarDetector.vehicles.union(["dashboard", "seat"]))
        }
    }
}

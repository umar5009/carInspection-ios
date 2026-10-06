import CoreBluetooth
import Foundation
import Observation

/// One paint thickness reading from a gauge (or typed in).
struct GaugeReading: Equatable, Identifiable {
    let id = UUID()
    let microns: Double
    let raw: String
    let date = Date()
}

/// Bluetooth-LE paint thickness gauges.
///
/// Gauges do not share one protocol, so this driver is deliberately generic:
/// it connects to the device the user picks, subscribes to every notifying characteristic and reads
/// numbers sent as text (e.g. "125", "125 um", "4.9 mil"), which is what most budget BLE gauges send.
/// Anything else is shown as hex in `lastRaw` so a decoder for that model can be added in `decodeBinary(_:)`.
///
/// Gauges that pair as a Bluetooth KEYBOARD (common "HID mode") need no driver: they type the value
/// into the focused reading field on the scan screen, which ends with Return.
@Observable
final class PaintGaugeService: NSObject {
    struct Device: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        let likelyGauge: Bool
        let peripheral: CBPeripheral
    }

    enum State: Equatable {
        case off, scanning, connecting(String), connected(String), failed(String)
    }

    private(set) var state: State = .off
    private(set) var devices: [Device] = []
    private(set) var lastReading: GaugeReading?
    private(set) var lastRaw = ""

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var textBuffer = ""
    @ObservationIgnored private var flushWork: DispatchWorkItem?

    /// Name fragments used by common automotive paint gauges. Only used to sort the list; any device can be picked.
    static let gaugeNameHints = ["PTG", "GAUGE", "PAINT", "NEX", "LS2", "CM-", "COAT", "THICK", "ET-", "R&D", "ELCOMETER", "CARSYS", "DPM"]

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    func startScan() {
        devices = []
        wantsScan = true
        if let central, central.state == .poweredOn {
            beginScan(central)
        } else if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning { state = .off }
    }

    func connect(_ device: Device) {
        guard let central else { return }
        central.stopScan()
        wantsScan = false
        peripheral = device.peripheral
        device.peripheral.delegate = self
        state = .connecting(device.name)
        central.connect(device.peripheral)
    }

    func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        state = .off
    }

    private func beginScan(_ central: CBCentralManager) {
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.state == .scanning else { return }
            central.stopScan()
            self.state = self.devices.isEmpty ? .failed("No Bluetooth devices found. Turn the gauge on and put it in Bluetooth mode.") : .off
        }
    }

    // MARK: Parsing

    /// Reads a thickness in µm from text. Accepts µm/um (default), mil(s) and mm.
    static func parse(_ text: String) -> Double? {
        let lower = text.lowercased().replacingOccurrences(of: ",", with: ".")
        guard let match = lower.firstMatch(of: /(\d+(?:\.\d+)?)/), var value = Double(match.output.1) else { return nil }
        if lower.contains("mil") { value *= 25.4 }
        else if lower.contains("mm") { value *= 1000 }
        return (5...5000).contains(value) ? value : nil
    }

    /// Handles one BLE notification. Text may arrive split over several packets, so it is buffered until a
    /// line end, or until the gauge goes quiet for 0.2 s.
    func receive(_ data: Data) {
        let printable = data.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 || $0 == 0xB5 }
        guard printable, let text = String(data: data, encoding: .isoLatin1) else {
            lastRaw = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            if let microns = decodeBinary(data) { emit(microns, raw: lastRaw) }
            return
        }
        textBuffer += text
        flushWork?.cancel()
        if textBuffer.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            flushText()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.flushText() }
            flushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func flushText() {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""
        guard !text.isEmpty else { return }
        lastRaw = text
        if let microns = Self.parse(text) { emit(microns, raw: text) }
    }

    private func emit(_ microns: Double, raw: String) {
        lastReading = GaugeReading(microns: microns, raw: raw)
    }

    /// Add a decoder for your gauge's binary packets here. `lastRaw` shows them as hex on the scan screen.
    private func decodeBinary(_ data: Data) -> Double? { nil }
}

extension PaintGaugeService: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsScan { beginScan(central) }
        case .unauthorized:
            state = .failed("Bluetooth permission is off. Allow it in Settings › Carlyze.")
        case .poweredOff:
            state = .failed("Bluetooth is off.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty else { return }
        let upper = name.uppercased()
        let likely = Self.gaugeNameHints.contains { upper.contains($0) }
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = RSSI.intValue
        } else {
            devices.append(Device(id: p.identifier, name: name, rssi: RSSI.intValue, likelyGauge: likely, peripheral: p))
        }
        devices.sort { ($0.likelyGauge ? 1 : 0, $0.rssi) > ($1.likelyGauge ? 1 : 0, $1.rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected(p.name ?? "Gauge")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = .failed(error?.localizedDescription ?? "Could not connect to the gauge.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if p.identifier == peripheral?.identifier { state = .failed("Gauge disconnected.") }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] where c.properties.contains(.notify) || c.properties.contains(.indicate) {
            p.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value, !data.isEmpty else { return }
        receive(data)
    }
}

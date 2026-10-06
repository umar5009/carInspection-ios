import CoreBluetooth
import Foundation
import Observation

/// Minimal ELM327 client for Bluetooth-LE OBD-II dongles (Vgate iCar Pro BLE, OBDLink CX, Veepeak BLE…).
/// Reads stored fault codes and a few live values so the engine score is backed by the ECU,
/// not only by sound. Also detects codes that were *recently cleared* (self-tests not finished,
/// few warm-ups / little distance since clearing) — a common trick by sellers to hide faults —
/// and reads pending codes and, on newer cars, the odometer stored in the ECU.
@Observable
final class OBDService: NSObject {
    enum State: Equatable { case idle, scanning, connecting, reading, done, failed(String) }
    private(set) var state: State = .idle
    private(set) var report = OBDReport()
    private(set) var log: [String] = []

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeChar: CBCharacteristic?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var queue: [(cmd: String, handle: (String) -> Void)] = []
    @ObservationIgnored private var onFinish: ((OBDReport) -> Void)?
    @ObservationIgnored private var timeout: DispatchWorkItem?

    private let services = [CBUUID(string: "FFF0"), CBUUID(string: "FFE0"), CBUUID(string: "18F0")]

    func start(onFinish: @escaping (OBDReport) -> Void) {
        self.onFinish = onFinish
        report = OBDReport()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func cancel() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        state = .idle
    }

    private func send(_ cmd: String, _ handle: @escaping (String) -> Void = { _ in }) {
        queue.append((cmd, handle))
        if queue.count == 1 { flush() }
    }

    private func flush() {
        guard let first = queue.first, let p = peripheral, let c = writeChar else { return }
        log.append("> \(first.cmd)")
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data((first.cmd + "\r").utf8), for: c, type: type)
        // A dongle that never answers must not freeze the whole read-out.
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.complete(with: "") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (first.cmd.hasPrefix("AT") ? 5 : 4), execute: work)
    }

    /// Finishes the command at the head of the queue and sends the next one.
    private func complete(with response: String) {
        timeout?.cancel()
        timeout = nil
        guard !queue.isEmpty else { return }
        let item = queue.removeFirst()
        if response.isEmpty { log.append("(no answer to \(item.cmd))") }
        item.handle(response)
        flush()
    }

    private func runSequence() {
        state = .reading
        ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"].forEach { send($0) }
        send("0101") { [weak self] r in            // MIL + DTC count + monitor readiness
            guard let self, let b = Self.bytes(r, mode: "41", pid: "01"), b.count >= 4 else { return }
            self.report.milOn = b[0] & 0x80 != 0
            self.report.monitorsNotReady = Self.monitorsNotReady(b: b[1], c: b[2], d: b[3])
        }
        send("03") { [weak self] r in self?.report.troubleCodes = Self.parseDTCs(r, mode: "43") }
        send("07") { [weak self] r in self?.report.pendingCodes = Self.parseDTCs(r, mode: "47") }
        send("0105") { [weak self] r in
            if let b = Self.bytes(r, mode: "41", pid: "05"), let a = b.first { self?.report.coolantTempC = Double(a) - 40 }
        }
        send("0106") { [weak self] r in
            if let b = Self.bytes(r, mode: "41", pid: "06"), let a = b.first { self?.report.fuelTrimShortPct = Double(a) / 1.28 - 100 }
        }
        send("0107") { [weak self] r in
            if let b = Self.bytes(r, mode: "41", pid: "07"), let a = b.first { self?.report.fuelTrimLongPct = Double(a) / 1.28 - 100 }
        }
        send("0130") { [weak self] r in
            if let b = Self.bytes(r, mode: "41", pid: "30"), let a = b.first { self?.report.warmupsSinceCleared = Int(a) }
        }
        send("0131") { [weak self] r in
            if let b = Self.bytes(r, mode: "41", pid: "31"), b.count >= 2 { self?.report.distanceSinceClearedKm = Int(b[0]) * 256 + Int(b[1]) }
        }
        send("01A6") { [weak self] r in            // odometer, newer cars only (0.1 km units)
            guard let self else { return }
            if let b = Self.bytes(r, mode: "41", pid: "A6"), b.count >= 4 {
                let raw = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
                if raw > 0 { self.report.ecuOdometerKm = Int(raw / 10) }
            }
            self.report.connected = true
            self.state = .done
            self.onFinish?(self.report)
        }
    }

    /// Emission self-tests that are supported but not yet complete (PID 01, bytes B–D).
    static func monitorsNotReady(b: UInt8, c: UInt8, d: UInt8) -> Int {
        let continuous = (b >> 4) & b & 0x07      // supported (bits 0–2) and incomplete (bits 4–6)
        let other = c & d                          // supported and incomplete
        return continuous.nonzeroBitCount + other.nonzeroBitCount
    }

    // MARK: Parsing

    static func bytes(_ response: String, mode: String, pid: String) -> [UInt8]? {
        let hex = response.uppercased().filter(\.isHexDigit)
        guard let range = hex.range(of: mode + pid) else { return nil }
        let payload = hex[range.upperBound...]
        var out: [UInt8] = []
        var i = payload.startIndex
        while i < payload.endIndex, let j = payload.index(i, offsetBy: 2, limitedBy: payload.endIndex) {
            if let v = UInt8(payload[i..<j], radix: 16) { out.append(v) }
            i = j
        }
        return out
    }

    static func parseDTCs(_ response: String, mode: String = "43") -> [String] {
        let hex = response.uppercased().filter(\.isHexDigit)
        guard let r = hex.range(of: mode) else { return [] }
        var body = String(hex[r.upperBound...])
        if body.count % 4 == 2 { body.removeFirst(2) }  // CAN: count byte
        var codes: [String] = []
        var i = body.startIndex
        while let j = body.index(i, offsetBy: 4, limitedBy: body.endIndex), i < body.endIndex {
            let chunk = String(body[i..<j]); i = j
            guard chunk != "0000", let v = UInt16(chunk, radix: 16) else { continue }
            let letter = ["P", "C", "B", "U"][Int(v >> 14)]
            let rest = String(v & 0x0FFF, radix: 16).uppercased()
            codes.append(letter + String((v >> 12) & 0x3, radix: 16) + String(repeating: "0", count: 3 - rest.count) + rest)
        }
        return codes
    }
}

extension OBDService: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting { state = .failed("Bluetooth is off or not permitted.") }
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.state == .scanning { central.stopScan(); self?.state = .failed("No OBD-II adapter found. Plug it in and turn the ignition on.") }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").uppercased()
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard ["OBD", "VLINK", "ICAR", "VEEPEAK", "ELM", "V-LINK", "KONNWEI"].contains(where: { name.contains($0) })
                || advertised.contains(where: services.contains) else { return }
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices(nil) }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = .failed(error?.localizedDescription ?? "Connection failed")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            if writeChar == nil, c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) { writeChar = c }
        }
        if writeChar != nil, state == .connecting { runSequence() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value, let s = String(data: d, encoding: .ascii) else { return }
        buffer += s
        guard buffer.contains(">") else { return }          // ELM prompt = response complete
        let response = buffer.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        log.append(response)
        complete(with: response)
    }
}

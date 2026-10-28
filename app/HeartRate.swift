import Foundation
import CoreBluetooth

// Standard Bluetooth Heart Rate Measurement, including optional contact detection.
func parseHeartRate(_ data: Data) -> Int? {
    let b = [UInt8](data)
    guard b.count >= 2 else { return nil }
    if b[0] & 0x04 != 0 && b[0] & 0x02 == 0 { return nil }
    let wide = b[0] & 1 != 0
    guard !wide || b.count >= 3 else { return nil }
    let bpm = Int(b[1]) + (wide ? Int(b[2]) * 256 : 0)
    return (30...240).contains(bpm) ? bpm : nil
}

struct ZoneDecision: Equatable {
    var delta: Double = 0
    var message: String
    var fault = false
}

// Pure control policy, also exercised without a Bluetooth connection in tests.
struct ZonePolicy {
    let low = 139.0, high = 149.0
    let maximumMph = 3.0
    private(set) var samples: [(time: TimeInterval, bpm: Double)] = []
    var lastAdjustment = -Double.infinity
    private(set) var settled = false
    private var excursionSince: TimeInterval?
    private var lastDirection = 0.0

    mutating func begin(at time: TimeInterval) {
        settled = false
        excursionSince = nil
        lastDirection = 0
        lastAdjustment = time
    }
    mutating func recordAdjustment(_ delta: Double, at time: TimeInterval) {
        lastAdjustment = time
        lastDirection = delta
        // After a sustained excursion, approach the center before holding again.
        settled = false
        excursionSince = nil
    }
    mutating func add(_ bpm: Int, at time: TimeInterval) {
        samples.append((time, Double(bpm)))
        samples.removeAll { time - $0.time > 35 }
        guard samples.count >= 4, let first = samples.first,
              time - first.time >= 25, let mean = average else { return }
        if !settled, (142...146).contains(mean) { settled = true }
        if settled && (mean < low || mean > high) {
            if excursionSince == nil { excursionSince = time }
        } else { excursionSince = nil }
    }
    mutating func samplesReset() { samples.removeAll(); settled = false; excursionSince = nil }
    var average: Double? {
        samples.isEmpty ? nil : samples.map(\.bpm).reduce(0, +) / Double(samples.count)
    }
    func decide(now: TimeInterval, mph: Double, minimumMph: Double,
                telemetryAge: Double, incline: Double, connected: Bool) -> ZoneDecision {
        guard connected, telemetryAge <= 5 else {
            return ZoneDecision(message: "Treadmill data unavailable; automatic control disabled", fault: true)
        }
        guard let latest = samples.last, now - latest.time <= 15 else {
            return ZoneDecision(message: "Heart rate stale; automatic control disabled", fault: true)
        }
        guard mph > 0.1 else { return ZoneDecision(message: "Belt stopped; automatic control disabled", fault: true) }
        guard abs(incline - 9) <= 0.5 else {
            return ZoneDecision(message: "Incline must be 9%; automatic control disabled", fault: true)
        }
        guard mph <= maximumMph + 0.15 else {
            return ZoneDecision(message: "Speed exceeds 3.0 mph ceiling; automatic control disabled", fault: true)
        }
        let recent = samples.filter { now - $0.time <= 35 }
        guard recent.count >= 4, let first = recent.first,
              latest.time - first.time >= 25 else { return ZoneDecision(message: "Collecting 30 seconds of heart rate") }
        let mean = recent.map(\.bpm).reduce(0, +) / Double(recent.count)
        guard now - lastAdjustment >= 45 else { return ZoneDecision(message: "Waiting for response to last adjustment") }
        if settled {
            if (low...high).contains(mean) { return ZoneDecision(message: "Settled: hold within 139-149 BPM") }
            guard let since = excursionSince, now - since >= 30 else {
                return ZoneDecision(message: "Waiting for 30 seconds persistently outside 139-149 BPM")
            }
        }
        // A small center band prevents chasing an exact 144 BPM reading.
        let delta: Double = mean < 142 && latest.bpm < 142 ? 0.1 : (mean > 146 && latest.bpm > 146 ? -0.1 : 0)
        guard delta != 0 else { return ZoneDecision(message: "Hold near 144 BPM") }
        if delta < 0 && mph <= minimumMph + 0.05 {
            return ZoneDecision(message: "Above target at minimum speed: pause or lower incline manually", fault: true)
        }
        if delta > 0 && mph >= maximumMph - 0.05 {
            return ZoneDecision(message: "Below center at 3.0 mph ceiling")
        }
        if lastDirection * delta < 0 && now - lastAdjustment < 120 {
            return ZoneDecision(message: "Waiting 120 seconds before reversing speed direction")
        }
        return ZoneDecision(delta: delta, message: delta > 0
                            ? "Approaching 144 BPM: raise speed 0.1 mph"
                            : "Approaching 144 BPM: lower speed 0.1 mph")
    }
}

@MainActor
final class HeartRateReceiver: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var bpm: Int?
    @Published var state = "Looking for HeartCast"
    var onSample: ((Int?) -> Void)?
    private var central: CBCentralManager!
    private var sensor: CBPeripheral?
    private let service = CBUUID(string: "180D")
    private let measurement = CBUUID(string: "2A37")
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan() }
        else { invalidate("Heart-rate Bluetooth unavailable") }
    }
    private func scan() {
        guard central.state == .poweredOn else { return }
        state = "Looking for HeartCast"
        central.scanForPeripherals(withServices: [service])
    }
    private func invalidate(_ reason: String) { bpm = nil; state = reason; onSample?(nil) }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        // Do not select an unrelated nearby person's heart-rate monitor.
        guard sensor == nil, name.localizedCaseInsensitiveContains("HeartCast") else { return }
        sensor = peripheral
        peripheral.delegate = self
        central.stopScan()
        state = "Connecting to \(name)"
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        sensor = nil; invalidate("HeartCast connection failed"); scan()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        sensor = nil; invalidate("HeartCast disconnected"); scan()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid == service {
            peripheral.discoverCharacteristics([measurement], for: s)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] where ch.uuid == measurement { peripheral.setNotifyValue(true, for: ch) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        state = error == nil && characteristic.isNotifying ? "HeartCast connected; waiting for BPM" : "HeartCast subscription failed"
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == measurement else { return }
        guard error == nil, let data = characteristic.value, let value = parseHeartRate(data) else {
            invalidate("Heart rate invalid or sensor contact lost"); return
        }
        bpm = value; state = "HeartCast live"; onSample?(value)
    }
}

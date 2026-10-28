// Walkpad: a small window that drives a Urevo walking pad (URTM...) over Bluetooth FTMS.
// On launch it connects, starts the belt if needed and applies the saved preset. While it
// runs it also answers http://127.0.0.1:47827/<command> so the `walkpad` CLI and agents can
// control the same session without Bluetooth permission. Closing the window quits the app.
import AppKit
import CoreBluetooth
import Network
import SwiftUI

let padNamePrefix = "URTM"  // Urevo treadmills advertise as URTM<model>, e.g. URTM054
let apiPort: UInt16 = 47827
let kmhPerMph = 1.609344

enum GATT {
    static let ftms = CBUUID(string: "1826")
    static let treadmillData = CBUUID(string: "2ACD")
    static let controlPoint = CBUUID(string: "2AD9")
    static let speedRange = CBUUID(string: "2AD4")
    static let inclineRange = CBUUID(string: "2AD5")
}

enum PadError: Error, CustomStringConvertible {
    case notConnected, timeout, refused(UInt8, UInt8), beltDidNotStart, unknownCommand(String)
    var description: String {
        switch self {
        case .notConnected: return "walking pad not connected"
        case .timeout: return "pad did not answer"
        case let .refused(op, code):
            let why = [2: "not supported", 3: "invalid parameter", 4: "failed", 5: "control not permitted"][Int(code)] ?? "code \(code)"
            return String(format: "pad refused 0x%02x: %@", op, why)
        case .beltDidNotStart: return "belt did not start within 10 s"
        case let .unknownCommand(c): return "unknown command '\(c)'"
        }
    }
}

struct Stats {
    var speedKmh = 0.0, inclinePct = 0.0
    var distanceM = 0, elapsedS = 0, steps = 0, kcal = 0
    var mph: Double { speedKmh / kmhPerMph }
    var miles: Double { Double(distanceM) / 1609.344 }
    var clock: String { String(format: "%d:%02d", elapsedS / 60, elapsedS % 60) }
}

/// Decode an FTMS Treadmill Data notification (0x2ACD).
func parseTreadmillData(_ data: Data) -> Stats {
    let count = data.count
    let b = [UInt8](data) + [UInt8](repeating: 0, count: 64)
    var i = 2, s = Stats()
    func u8() -> Int { defer { i += 1 }; return Int(b[i]) }
    func u16() -> Int { defer { i += 2 }; return Int(b[i]) | Int(b[i + 1]) << 8 }
    func s16() -> Int { Int(Int16(bitPattern: UInt16(u16()))) }
    func u24() -> Int { defer { i += 3 }; return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 }
    guard count >= 2 else { return s }
    let flags = Int(b[0]) | Int(b[1]) << 8
    if flags & 0x0001 == 0 { s.speedKmh = Double(u16()) / 100 }
    if flags & 0x0002 != 0 { _ = u16() }
    if flags & 0x0004 != 0 { s.distanceM = u24() }
    if flags & 0x0008 != 0 { s.inclinePct = Double(s16()) / 10; _ = s16() }
    if flags & 0x0010 != 0 { _ = u16(); _ = u16() }
    if flags & 0x0020 != 0 { _ = u8() }
    if flags & 0x0040 != 0 { _ = u8() }
    if flags & 0x0080 != 0 { s.kcal = u16(); _ = u16(); _ = u8() }
    if flags & 0x0100 != 0 { _ = u8() }
    if flags & 0x0200 != 0 { _ = u8() }
    if flags & 0x0400 != 0 { s.elapsedS = u16() }
    if flags & 0x0800 != 0 { _ = u16() }
    if flags & 0x1000 != 0 { _ = u16(); _ = u16() }
    // Bit 13 is reserved in the FTMS spec; this firmware puts a 24-bit step count there.
    if flags & 0x2000 != 0, count >= i + 3 { s.steps = u24() }
    return s
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

@MainActor
final class Pad: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var stats = Stats()
    @Published var state = "Starting Bluetooth…"
    @Published var ready = false
    @Published var targetMph: Double?
    @Published var targetIncline: Double?
    @Published var message = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var speedRangeKmh = (lo: 0.96, hi: 6.43)
    private var inclineRange = (lo: 0.0, hi: 9.0, step: 1.0)
    private var pending: (id: Int, cont: CheckedContinuation<Data, Error>)?
    private var nextId = 0
    private var tail: Task<Void, Never>?
    private var hasControl = false
    private var presetApplied = false
    private var lastCommand = Date.distantPast
    let heart = HeartRateReceiver()
    @Published var heartBpm: Int?
    @Published var zoneEnabled = false
    @Published var zonePreview = "Waiting for live data"
    @Published var zoneMessage = "Preview only; target 139-149 BPM"
    private var zone = ZonePolicy()
    private var zoneGeneration = 0
    private var zoneBusy = false
    private var zoneTimer: Timer?
    private var telemetryTime = Date.distantPast
    private var heartTime = Date.distantPast
    private let monitorOnly = CommandLine.arguments.contains("--monitor")

    var presetMph: Double {
        get { UserDefaults.standard.double(forKey: "presetMph") }
        set { UserDefaults.standard.set(newValue, forKey: "presetMph") }
    }
    var presetIncline: Double {
        get { UserDefaults.standard.double(forKey: "presetIncline") }
        set { UserDefaults.standard.set(newValue, forKey: "presetIncline") }
    }

    override init() {
        UserDefaults.standard.register(defaults: ["presetMph": 2.5, "presetIncline": 9.0])
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        heart.onSample = { [weak self] bpm in
            guard let self else { return }
            heartBpm = bpm
            if let bpm {
                heartTime = Date()
                zone.add(bpm, at: Date.timeIntervalSinceReferenceDate)
            } else {
                zone.samplesReset()
                disableZone("Heart rate lost; automatic control disabled")
            }
        }
        zoneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.zoneTick() }
        }
    }

    // MARK: Bluetooth plumbing

    private func scan() {
        state = "Looking for the walking pad…"
        central.scanForPeripherals(withServices: [GATT.ftms])
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: scan()
        case .unauthorized: state = "Allow Bluetooth for Walkpad in System Settings › Privacy"
        case .poweredOff: state = "Bluetooth is off"
        default: state = "Bluetooth unavailable"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name, name.hasPrefix(padNamePrefix) else { return }
        c.stopScan()
        peripheral = p
        p.delegate = self
        state = "Connecting…"
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([GATT.ftms])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { scan() }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        disableZone("Pad disconnected; automatic control disabled")
        ready = false
        hasControl = false
        controlPoint = nil
        failPending(PadError.notConnected)
        scan()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == GATT.ftms {
            p.discoverCharacteristics([GATT.treadmillData, GATT.controlPoint, GATT.speedRange, GATT.inclineRange], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            switch ch.uuid {
            case GATT.treadmillData: p.setNotifyValue(true, for: ch)
            case GATT.controlPoint: controlPoint = ch; p.setNotifyValue(true, for: ch)
            default: p.readValue(for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let v = ch.value else { return }
        let b = [UInt8](v)
        switch ch.uuid {
        case GATT.treadmillData:
            stats = parseTreadmillData(v)
            telemetryTime = Date()
            if !ready, controlPoint?.isNotifying == true { becomeReady() }
        case GATT.controlPoint:
            if let pending { self.pending = nil; pending.cont.resume(returning: v) }
        case GATT.speedRange where b.count >= 4:
            speedRangeKmh = (Double(le(b, 0)) / 100, Double(le(b, 2)) / 100)
        case GATT.inclineRange where b.count >= 6:
            inclineRange = (Double(Int16(bitPattern: UInt16(le(b, 0)))) / 10,
                            Double(Int16(bitPattern: UInt16(le(b, 2)))) / 10, Double(le(b, 4)) / 10)
        default: break
        }
    }

    private func le(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }

    private func becomeReady() {
        ready = true
        state = "Connected"
        guard !monitorOnly, !presetApplied else { return }
        presetApplied = true
        Task { message = await run(applyPreset) }
    }

    private func failPending(_ e: Error) {
        if let pending { self.pending = nil; pending.cont.resume(throwing: e) }
    }

    // MARK: Control point

    private func send(_ bytes: [UInt8]) async throws {
        guard let p = peripheral, let cp = controlPoint, ready else { throw PadError.notConnected }
        nextId += 1
        let id = nextId
        let reply: Data = try await withCheckedThrowingContinuation { cont in
            pending = (id, cont)
            p.writeValue(Data(bytes), for: cp, type: .withResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.pending?.id == id { self?.failPending(PadError.timeout) }
            }
        }
        let r = [UInt8](reply)
        guard r.count >= 3, r[0] == 0x80, r[1] == bytes[0], r[2] == 1 else { throw PadError.refused(bytes[0], r.count >= 3 ? r[2] : 0) }
    }

    private func ensureControl() async throws {
        if !hasControl { try await send([0x00]); hasControl = true }
    }

    /// Run commands one at a time; returns a short message for the user.
    func run(_ op: @escaping @MainActor () async throws -> String) async -> String {
        let prev = tail
        let task = Task { () -> String in
            await prev?.value
            do { return try await op() } catch { return "Error: \(error)" }
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Notches build on the last target while the belt ramps toward it.
    private var baseMph: Double {
        if let t = targetMph, Date().timeIntervalSince(lastCommand) < 8 || abs(t - stats.mph) < 0.15 { return t }
        return (stats.mph * 10).rounded() / 10
    }
    private var baseIncline: Double {
        if let t = targetIncline, Date().timeIntervalSince(lastCommand) < 8 || abs(t - stats.inclinePct) < 0.5 { return t }
        return stats.inclinePct.rounded()
    }

    func setSpeed(_ mph: Double) async throws -> String {
        guard stats.speedKmh > 0 else { throw PadError.beltDidNotStart }
        try await ensureControl()
        let m = (min(max(mph, speedRangeKmh.lo / kmhPerMph), speedRangeKmh.hi / kmhPerMph) * 10).rounded() / 10
        // The firmware truncates the target to 0.1 km/h, converts to mph, then truncates to
        // 0.1 mph. Round up to the next 0.1 km/h so the belt lands on the requested mph.
        let kmh = min(ceil((m * kmhPerMph * 10 * 1e6).rounded() / 1e6) / 10, speedRangeKmh.hi)
        try await send([0x02] + le16(Int((kmh * 100).rounded())))
        targetMph = m
        lastCommand = Date()
        return String(format: "speed %.1f mph", m)
    }

    func setIncline(_ pct: Double) async throws -> String {
        try await ensureControl()
        let step = inclineRange.step > 0 ? inclineRange.step : 1
        let v = min(max((pct / step).rounded() * step, inclineRange.lo), inclineRange.hi)
        try await send([0x03] + le16(Int((v * 10).rounded())))
        targetIncline = v
        lastCommand = Date()
        return String(format: "incline %.0f%%", v)
    }

    func startBelt() async throws -> String {
        try await ensureControl()
        try await send([0x07])
        for _ in 0..<100 where stats.speedKmh == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard stats.speedKmh > 0 else { throw PadError.beltDidNotStart }
        return String(format: "started at %.1f mph", stats.mph)
    }

    func applyPreset() async throws -> String {
        let started = stats.speedKmh == 0 ? try await startBelt() + ", " : ""
        let inc = try await setIncline(presetIncline)
        return started + inc + ", " + (try await setSpeed(presetMph))
    }

    func savePreset() {
        presetMph = targetMph ?? (stats.mph * 10).rounded() / 10
        presetIncline = targetIncline ?? stats.inclinePct.rounded()
        message = String(format: "preset saved: %.1f mph, incline %.0f%%", presetMph, presetIncline)
    }

    // MARK: Heart-rate preview and opt-in speed control

    private var zoneDecision: ZoneDecision {
        zone.decide(now: Date.timeIntervalSinceReferenceDate, mph: stats.mph,
                    minimumMph: ceil(speedRangeKmh.lo / kmhPerMph * 10) / 10,
                    telemetryAge: Date().timeIntervalSince(telemetryTime),
                    incline: stats.inclinePct, connected: ready)
    }

    func disableZone(_ reason: String) {
        zoneGeneration += 1
        zoneEnabled = false
        zoneMessage = reason
    }

    private func zoneTick() {
        if Date().timeIntervalSince(heartTime) > 15 { heartBpm = nil }
        let decision = zoneDecision
        zonePreview = decision.message
        if !zoneEnabled { return }
        if decision.fault { disableZone(decision.message); return }
        zoneMessage = decision.message
        guard decision.delta != 0, !zoneBusy else { return }
        zoneBusy = true
        let generation = zoneGeneration
        Task {
            let result = await run { [self] in
                guard zoneEnabled, generation == zoneGeneration else { return "Automatic adjustment cancelled" }
                try await ensureControl()
                guard zoneEnabled, generation == zoneGeneration else { return "Automatic adjustment cancelled" }
                let fresh = zoneDecision
                guard !fresh.fault else { disableZone(fresh.message); return fresh.message }
                guard fresh.delta != 0 else { return fresh.message }
                let result = try await setSpeed(min(zone.maximumMph, baseMph + fresh.delta))
                zone.recordAdjustment(fresh.delta, at: Date.timeIntervalSinceReferenceDate)
                return result
            }
            if generation == zoneGeneration {
                if result.hasPrefix("Error") { disableZone(result) }
                else { zoneMessage = result }
            }
            zoneBusy = false
        }
    }

    private func enableZone() -> String {
        let decision = zoneDecision
        guard !decision.fault, zone.samples.count >= 4,
              let first = zone.samples.first, let last = zone.samples.last,
              last.time - first.time >= 25 else {
            return "Error: need fresh heart rate for 30 seconds, running belt at no more than 3.0 mph, and incline 9%. " + decision.message
        }
        zoneGeneration += 1
        zoneEnabled = true
        zone.begin(at: Date.timeIntervalSinceReferenceDate)
        zoneMessage = "Active: 139-149 BPM, incline 9%, speed ceiling 3.0 mph"
        return zoneMessage
    }

    // MARK: Commands shared by the window and the local API

    var statusDict: [String: Any] {
        // Decimal keeps JSON output at "2.6" instead of "2.6000000000000001".
        func num(_ v: Double?, _ places: Int = 1) -> Any {
            v.flatMap { Decimal(string: String(format: "%.\(places)f", $0)) } ?? NSNull()
        }
        return ["connected": ready, "state": state, "mph": num(stats.mph), "incline": num(stats.inclinePct, 0),
                "target_mph": num(targetMph), "target_incline": num(targetIncline, 0),
                "miles": num(stats.miles, 2), "elapsed": stats.clock, "steps": stats.steps, "kcal": stats.kcal,
                "preset_mph": num(presetMph), "preset_incline": num(presetIncline, 0),
                "heart_bpm": heartBpm.map { $0 as Any } ?? NSNull(),
                "heart_state": heart.state, "heart_age_seconds": heartTime == .distantPast ? NSNull() : num(Date().timeIntervalSince(heartTime)),
                "zone_enabled": zoneEnabled, "zone_low": 139, "zone_high": 149,
                "zone_max_mph": zone.maximumMph, "zone_message": zoneMessage,
                "zone_preview": zoneDecision.message]
    }

    func handle(_ path: String) async -> [String: Any] {
        let comps = URLComponents(string: "http://localhost" + path)
        let cmd = (comps?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let value = (comps?.queryItems?.first?.value).flatMap(Double.init)
        if cmd == "zone-off" {
            disableZone("Automatic control off; speed unchanged")
            return ["ok": true, "msg": zoneMessage, "status": statusDict]
        }
        if cmd == "zone-on" {
            let result = enableZone()
            return ["ok": !result.hasPrefix("Error"), "msg": result, "status": statusDict]
        }
        if cmd == "heart" { return ["ok": heartBpm != nil, "msg": heart.state, "status": statusDict] }
        if cmd == "status" || cmd.isEmpty { return ["ok": ready, "msg": state, "status": statusDict] }
        if cmd == "save-preset" { savePreset(); return ["ok": true, "msg": message, "status": statusDict] }
        if value?.isFinite == false { return ["ok": false, "msg": "Invalid numeric value", "status": statusDict] }
        if ["preset", "climb", "up", "down", "speed", "incline-up", "incline-down", "incline", "start", "pause", "stop"].contains(cmd) {
            disableZone("Manual command; automatic control off")
        }
        guard ready else { return ["ok": false, "msg": state, "status": statusDict] }
        let msg = await run { [self] in
            switch cmd {
            case "preset", "climb": return try await applyPreset()
            case "up": return try await setSpeed(baseMph + (value ?? 0.1))
            case "down": return try await setSpeed(baseMph - (value ?? 0.1))
            case "speed": return try await setSpeed(value ?? presetMph)
            case "incline-up": return try await setIncline(baseIncline + (value ?? 1))
            case "incline-down": return try await setIncline(baseIncline - (value ?? 1))
            case "incline": return try await setIncline(value ?? presetIncline)
            case "start": return try await startBelt()
            case "pause": try await send([0x08, 0x02]); return "paused"
            case "stop": try await send([0x08, 0x01]); targetMph = nil; return "stopped"
            default: throw PadError.unknownCommand(cmd)
            }
        }
        message = msg
        return ["ok": !msg.hasPrefix("Error"), "msg": msg, "status": statusDict]
    }

    func act(_ cmd: String) { Task { _ = await handle("/" + cmd) } }
}

/// Minimal loopback-only HTTP endpoint: GET /<command>[?v=<number>] -> JSON.
final class API {
    private let listener: NWListener

    @MainActor init(pad: Pad) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: apiPort)!)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                Task { @MainActor in
                    let body = await pad.handle(path)
                    let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
                    var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
                    resp.append(json)
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        listener.start(queue: .main)
    }
}

// MARK: UI

struct Dial: View {
    let title: String, value: String, unit: String, target: String?
    let minus: () -> Void, plus: () -> Void
    let minusKey: KeyEquivalent, plusKey: KeyEquivalent

    var body: some View {
        HStack(spacing: 12) {
            Button(action: minus) { Image(systemName: "minus").frame(width: 44, height: 44) }
                .keyboardShortcut(minusKey, modifiers: [])
            VStack(spacing: 0) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
                Text(target.map { "→ \($0)" } ?? " ").font(.caption).foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity)
            Button(action: plus) { Image(systemName: "plus").frame(width: 44, height: 44) }
                .keyboardShortcut(plusKey, modifiers: [])
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

struct ContentView: View {
    @ObservedObject var pad: Pad
    @AppStorage("floating") private var floating = true

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var speedTarget: String? {
        guard let t = pad.targetMph, abs(t - pad.stats.mph) >= 0.05 else { return nil }
        return String(format: "%.1f", t)
    }
    private var inclineTarget: String? {
        guard let t = pad.targetIncline, abs(t - pad.stats.inclinePct) >= 0.5 else { return nil }
        return String(format: "%.0f", t)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Circle().fill(pad.ready ? .green : .orange).frame(width: 8, height: 8)
                Text(pad.state).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { floating.toggle(); applyFloating() } label: {
                    Image(systemName: floating ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help("Keep on top")
            }
            Dial(title: "SPEED", value: String(format: "%.1f", pad.stats.mph), unit: "mph", target: speedTarget,
                 minus: { pad.act("down") }, plus: { pad.act("up") }, minusKey: .downArrow, plusKey: .upArrow)
            Dial(title: "INCLINE", value: String(format: "%.0f", pad.stats.inclinePct), unit: "%", target: inclineTarget,
                 minus: { pad.act("incline-down") }, plus: { pad.act("incline-up") }, minusKey: .leftArrow, plusKey: .rightArrow)
            HStack {
                stat("miles", String(format: "%.2f", pad.stats.miles))
                stat("time", pad.stats.clock)
                stat("steps", "\(pad.stats.steps)")
                stat("kcal", "\(pad.stats.kcal)")
            }
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 5) {
                Text(pad.heartBpm.map { "Heart rate: \($0) BPM" } ?? "Waiting for HeartCast")
                    .font(.headline).monospacedDigit()
                Text("Target 139-149 BPM · incline 9% · ceiling 3.0 mph").font(.caption2)
                HStack {
                    Button("Enable Zone 2") { pad.act("zone-on") }.disabled(pad.zoneEnabled)
                    Button("Disable") { pad.act("zone-off") }
                }
                Text(pad.zoneMessage).font(.caption).fixedSize(horizontal: false, vertical: true)
                if !pad.zoneEnabled { Text(pad.zonePreview).font(.caption2).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Start") { pad.act("start") }
                Button("Pause") { pad.act("pause") }
                Button("Stop") { pad.act("stop") }.keyboardShortcut(".", modifiers: .command)
                Spacer()
                Menu("Preset") {
                    Button(String(format: "Go to preset (%.1f mph, %.0f%%)", pad.presetMph, pad.presetIncline)) { pad.act("preset") }
                    Button("Save current as preset") { pad.savePreset() }
                }
                .fixedSize()
            }
            .disabled(!pad.ready)
            Text(pad.message.isEmpty ? " " : pad.message)
                .font(.caption).foregroundStyle(pad.message.hasPrefix("Error") ? .red : .secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { DispatchQueue.main.async(execute: applyFloating) }
    }

    private func applyFloating() {
        NSApp.windows.forEach { $0.level = floating ? .floating : .normal }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WalkpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var pad = Pad()
    @State private var api: API?

    var body: some Scene {
        Window("Walkpad", id: "main") {
            ContentView(pad: pad)
                .onAppear {
                    guard api == nil else { return }
                    do { api = try API(pad: pad) } catch { pad.message = "Error: local API unavailable (\(error))" }
                }
        }
        .windowResizability(.contentSize)
    }
}

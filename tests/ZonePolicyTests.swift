import Foundation

@main struct Tests {
    static func main() {
        assert(parseHeartRate(Data([0, 144])) == 144)
        assert(parseHeartRate(Data([1, 144, 0])) == 144)
        assert(parseHeartRate(Data([1, 144])) == nil)
        assert(parseHeartRate(Data([4, 144])) == nil)
        assert(parseHeartRate(Data([6, 144])) == 144)
        assert(parseHeartRate(Data([0, 0])) == nil)
        func policy(_ bpm: Int) -> ZonePolicy {
            var p = ZonePolicy()
            for t in stride(from: 0, through: 30, by: 5) { p.add(bpm, at: Double(t)) }
            return p
        }
        func decide(_ p: ZonePolicy, now: Double = 30, mph: Double = 2,
                    age: Double = 0, incline: Double = 9, connected: Bool = true) -> ZoneDecision {
            p.decide(now: now, mph: mph, minimumMph: 0.6,
                     telemetryAge: age, incline: incline, connected: connected)
        }
        assert(decide(policy(135)).delta == 0.1)
        assert(decide(policy(155)).delta == -0.1)
        assert(decide(policy(144)).delta == 0)
        assert(decide(policy(139)).delta == 0.1)
        assert(decide(policy(149)).delta == -0.1)
        assert(decide(policy(130), mph: 2.5).delta == 0.1)
        assert(decide(policy(130), mph: 3.0).delta == 0)
        assert(decide(policy(155), mph: 0.6).fault)
        assert(decide(policy(140), mph: 0).fault)
        assert(decide(policy(140), now: 46).fault)
        assert(decide(policy(140), age: 6).fault)
        assert(decide(policy(140), incline: 8).fault)
        assert(decide(policy(140), connected: false).fault)
        assert(decide(policy(140), mph: 3.3).fault)
        var p = policy(130)
        p.lastAdjustment = 20
        assert(decide(p).delta == 0)
        p.lastAdjustment = -100
        p.add(155, at: 31)
        assert(decide(p, now: 31).delta == 0)
        p.samplesReset()
        p.add(130, at: 30)
        assert(decide(p).delta == 0)
        // Settle near center, then tolerate either edge for minutes without commands.
        var hold = policy(144)
        assert(hold.settled)
        for t in stride(from: 35, through: 300, by: 5) {
            hold.add(t < 150 ? 139 : 149, at: Double(t))
            assert(decide(hold, now: Double(t)).delta == 0)
        }
        // A brief excursion does not trigger a correction; a sustained one does.
        var excursion = policy(144)
        for t in stride(from: 35, through: 60, by: 5) {
            excursion.add(155, at: Double(t))
            assert(decide(excursion, now: Double(t)).delta == 0)
        }
        for t in stride(from: 65, through: 100, by: 5) { excursion.add(155, at: Double(t)) }
        assert(decide(excursion, now: 100).delta == -0.1)
        // After an increase, no reversal until 120 seconds, even after normal cooldown.
        var reversal = policy(130)
        reversal.recordAdjustment(0.1, at: 30)
        for t in stride(from: 35, through: 145, by: 5) {
            reversal.add(155, at: Double(t))
            assert(decide(reversal, now: Double(t)).delta == 0)
        }
        reversal.add(155, at: 150)
        assert(decide(reversal, now: 150).delta == -0.1)
        // Same-direction adjustment still respects the full 45-second cooldown.
        var cooldown = policy(130)
        cooldown.recordAdjustment(0.1, at: 30)
        for t in stride(from: 35, through: 70, by: 5) {
            cooldown.add(130, at: Double(t))
            assert(decide(cooldown, now: Double(t)).delta == 0)
        }
        cooldown.add(130, at: 75)
        assert(decide(cooldown, now: 75).delta == 0.1)
        print("PASS: centering, edge holding, persistent excursions, reversal delay, cooldown; HR decoding, boundaries, warmup, cooldown, dropout, ceiling, minimum, incline and telemetry guards")
    }
}

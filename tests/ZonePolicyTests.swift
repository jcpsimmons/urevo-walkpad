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
        assert(decide(policy(139)).delta == 0)
        assert(decide(policy(149)).delta == 0)
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
        print("PASS: HR decoding, boundaries, warmup, cooldown, dropout, ceiling, minimum, incline and telemetry guards")
    }
}

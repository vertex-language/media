// check-mix: a tone comes out at its pitch and length, panned where it
// was put; the limiter never lets a sample past 1; a lowpass passes the
// low and stops the high; a player plays a buffer through and loops;
// finished voices leave the mix. And how long a second of a busy mix
// takes to make.
//
//     vsc run check-mix
package main

import (
    "math"
    "media/audio"
    "media/mix"
    "time"
)

var failures = 0

func check(_ ok: bool, _ what: string) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

func crossings(_ s: [float32], every: int = 1, from: int = 0) -> int {
    var n = 0
    var i = from + every
    while i < s.count {
        if (s[i - every] < 0) != (s[i] < 0) { n += 1 }
        i += every
    }
    return n
}

func rms(_ s: [float32]) -> float32 {
    var a: float32 = 0
    for x in s { a += x * x }
    return math.Sqrt(a / float32(max(1, s.count)))
}

func main() -> int32 {
    let rate = 48000
    let m = mix.Mixer(rate: rate)
    m.Gain = 1
    let v = m.Add(mix.Tone(440, seconds: 0.5, rate: rate, harmonic: 0))
    v.Pan = -1
    var all: [float32] = []
    for _ in 0..<30 { all += m.Render(frames: 1024) }
    // Left channel: 440 Hz is 880 crossings a second, 440 in half a second.
    let c = crossings(all, every: 2)
    check(c > 430 && c < 450, "a 440 Hz tone for 0.5 s crosses zero \(c) times")
    var right: float32 = 0
    for i in 0..<(all.count / 2) { right = math.Max(right, math.Abs(all[i * 2 + 1])) }
    check(right < 0.001, "panned hard left, the right is silent (\(right))")
    check(m.Voices.isEmpty, "and when it ends it leaves the mix")

    let loud = mix.Mixer(rate: rate)
    loud.Gain = 4
    for f in [100, 230, 370] { loud.Add(mix.Tone(float32(f), seconds: 1, rate: rate, gain: 1)) }
    var top: float32 = 0
    for _ in 0..<10 {
        for x in loud.Render(frames: 1024) { top = math.Max(top, math.Abs(x)) }
    }
    check(top <= 1 && loud.Peak > 1, "the limiter holds \(loud.Peak) to \(top)")

    // A lowpass at 500 Hz: 100 Hz through, 5 kHz down by far.
    func through(_ f: float32) -> float32 {
        var lp = mix.Biquad(.lowpass, frequency: 500, rate: rate)
        var s: [float32] = []
        for i in 0..<4800 { s.append(lp.Run(math.Sin(2 * float32(math.Pi) * f * float32(i) / float32(rate)))) }
        return rms(Array(s[2400...]))
    }
    let low = through(100), high = through(5000)
    check(low > 0.6 && high < 0.02, "a lowpass passes 100 Hz (\(low)) and stops 5 kHz (\(high))")

    // A player: 1000 samples of a ramp at half the mix rate plays 2000
    // frames; looping, it keeps going.
    var ramp: [float32] = []
    for i in 0..<1000 { ramp.append(float32(i) / 1000) }
    let p = mix.Player(audio.Buffer(samples: ramp, rate: rate / 2), mixRate: rate)
    let pm = mix.Mixer(rate: rate)
    pm.Gain = 1
    pm.Add(p.Voice())
    var frames = 0
    while !pm.Voices.isEmpty && frames < 10000 {
        _ = pm.Render(frames: 256)
        frames += 256
    }
    check(frames >= 1990 && frames <= 2304, "a player plays a buffer through at its rate (\(frames) frames)")
    let lp = mix.Player(audio.Buffer(samples: ramp, rate: rate), mixRate: rate)
    lp.Loop = true
    let lm = mix.Mixer(rate: rate)
    lm.Add(lp.Voice())
    for _ in 0..<20 { _ = lm.Render(frames: 256) }
    check(lm.Voices.count == 1, "and looping, keeps going")

    // A voice told to wait starts that many frames in.
    let wm = mix.Mixer(rate: rate)
    wm.Gain = 1
    let late = wm.Add(mix.Tone(440, seconds: 0.1, rate: rate, harmonic: 0))
    late.Wait = 1500
    let first = wm.Render(frames: 1024) + wm.Render(frames: 1024)
    var start = -1
    for i in 0..<(first.count / 2) where start < 0 && math.Abs(first[i * 2]) > 1e-6 { start = i }
    check(start >= 1500 && start < 1510, "a voice that waits starts when it should (frame \(start))")

    // A busy mix: eight voices, each a filtered noise and a tone.
    let busy = mix.Mixer(rate: rate)
    for k in 0..<8 {
        var n = mix.Noise(seed: uint32(k + 1))
        var bp = mix.Biquad(.bandpass, frequency: 800 + float32(k) * 100, q: 2, rate: rate)
        var ph: float32 = 0
        busy.Add(mix.Voice { buf, count in
            for i in 0..<count {
                ph += 0.01
                if ph > 1 { ph -= 1 }
                buf[i] = bp.Run(n.Next()) * 0.2 + math.Sin(ph * 6.2832) * 0.1
            }
            return true
        })
    }
    let t0 = time.Instant.Now()
    for _ in 0..<(rate / 1024) { _ = busy.Render(frames: 1024) }
    let ms = t0.Elapsed().AsMilliseconds()
    check(ms < 1000, "a second of eight voices takes \(ms) ms to make")
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}

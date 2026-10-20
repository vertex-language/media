// play-tone plays a chord out of the speakers for a second and a half,
// writing a little ahead the way a game would, and says whether the
// device ever ran dry. It needs a sound device, so it isn't part of the
// offline checks.
//
//     vsc run play-tone
package main

import (
    "media/device"
    "media/mix"
    "time"
)

func main() async -> int32 {
    let out: device.Output
    do {
        out = try device.Output.Open(rate: 48000, channels: 2)
    } catch {
        print("play-tone: \(error)")
        return 1
    }
    defer { out.Close() }
    let m = mix.Mixer(rate: out.Rate)
    for (i, f) in [261.63, 329.63, 392.0].enumerated() {
        let v = m.Add(mix.Tone(float32(f), seconds: 1.5, rate: out.Rate, gain: 0.25))
        v.Pan = float32(i - 1) * 0.6
    }
    let begun = time.Instant.Now()
    while !m.Voices.isEmpty {
        // Keep about 60 ms queued.
        let want = out.Rate * 6 / 100 - out.Queued
        if want > 0 { out.Write(m.Render(frames: want)) }
        try? await time.Sleep(time.Duration.Milliseconds(10))
    }
    while out.Queued > 0 { try? await time.Sleep(time.Duration.Milliseconds(10)) }
    print("play-tone: \(begun.Elapsed().AsMilliseconds()) ms at \(out.Rate) Hz, \(out.Underruns) underruns")
    return 0
}

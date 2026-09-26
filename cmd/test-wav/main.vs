// media/wav and media/audio against libsndfile (testdata/oracle/
// wav_oracle.py). Every fixture libsndfile wrote -- 8, 16, 24 and 32-bit
// PCM and 32 and 64-bit float, at one, two and three channels -- decodes
// to exactly the samples libsndfile reads from it, and the signal they
// were made from encodes to the samples libsndfile stored. What this
// writes goes to testdata/out, for `wav_oracle.py check testdata/out` to
// read back through libsndfile. Then the resampler: a tone keeps its
// level, a constant stays constant, and what the lower rate cannot hold
// is filtered out rather than aliased.
package main

import (
    "fs"
    "math"
    "media/audio"
    "media/wav"
)

var failures = 0

func check(_ ok: bool, _ what: string) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

func f32(_ path: string) throws -> [float32] {
    let b = try fs.ReadFile(fs.Path(path))
    var out = [float32](repeating: 0, count: b.count / 4)
    for i in 0..<out.count {
        let v = uint32(b[4 * i]) | uint32(b[4 * i + 1]) << 8 | uint32(b[4 * i + 2]) << 16 | uint32(b[4 * i + 3]) << 24
        out[i] = float32(bitPattern: v)
    }
    return out
}

// firstDiff is where two sample arrays first differ, or -1.
func firstDiff(_ a: [float32], _ b: [float32]) -> int {
    if a.count != b.count {
        return min(a.count, b.count)
    }
    for i in 0..<a.count {
        if a[i] != b[i] {
            return i
        }
    }
    return -1
}

let formats: [(string, wav.Format)] = [("pcm8", .pcm8), ("pcm16", .pcm16), ("pcm24", .pcm24),
                                       ("pcm32", .pcm32), ("float32", .float32), ("float64", .float64)]
try fs.CreateDir(fs.Path("testdata/out"), all: true)

for ch in 1...3 {
    let signal = audio.Buffer(samples: try f32("testdata/wav/signal\(ch).f32"), rate: 24000, channels: ch)
    for (name, format) in formats {
        let base = "testdata/wav/\(name)-\(ch)ch"
        do {
            let want = try f32(base + ".f32")
            let (got, info) = try wav.Decode(try fs.ReadFile(fs.Path(base + ".wav")))
            let at = firstDiff(got.Samples, want)
            check(at < 0 && info.Format == format && info.Rate == 24000 && info.Channels == ch && info.Frames == 1200,
                  "decode \(name) \(ch)ch: \(info.Frames) frames as libsndfile reads them" + (at < 0 ? "" : " (differs at \(at): \(at < got.Samples.count ? got.Samples[at] : 0) vs \(at < want.count ? want[at] : 0))"))

            let bytes = wav.Encode(signal, format: format)
            let (back, _) = try wav.Decode(bytes)
            let at2 = firstDiff(back.Samples, want)
            check(at2 < 0, "encode \(name) \(ch)ch: the samples libsndfile stores" + (at2 < 0 ? "" : " (differs at \(at2): \(back.Samples[at2]) vs \(want[at2]), from \(signal.Samples[at2]))"))
            try fs.WriteFile(fs.Path("testdata/out/\(name)-\(ch)ch.wav"), bytes)
            try fs.WriteFile(fs.Path("testdata/out/\(name)-\(ch)ch.f32"), try fs.ReadFile(fs.Path(base + ".f32")))
        } catch {
            check(false, "\(name) \(ch)ch: \(error)")
        }
    }
}

// Refusals.
do {
    _ = try wav.Decode(Array("RIFX\u{0}\u{0}\u{0}\u{0}WAVE".utf8))
    check(false, "a file that is not RIFF/WAVE is refused")
} catch {
    check("\(error)".contains("not a RIFF/WAVE"), "a file that is not RIFF/WAVE is refused: \(error)")
}
do {
    var b = try fs.ReadFile(fs.Path("testdata/wav/pcm16-1ch.wav"))
    b[20] = 2  // format tag 2, Microsoft ADPCM
    _ = try wav.Decode(b)
    check(false, "ADPCM is refused")
} catch {
    check("\(error)".contains("unsupported"), "ADPCM is refused: \(error)")
}

// The resampler.
func tone(_ hz: float32, rate: int, seconds: float32) -> audio.Buffer {
    let n = int(float32(rate) * seconds)
    var s = [float32](repeating: 0, count: n)
    for i in 0..<n {
        s[i] = 0.5 * math.Sin(2 * 3.14159265 * hz * float32(i) / float32(rate))
    }
    return audio.Buffer(samples: s, rate: rate)
}

// rms over the middle half, away from the edges.
func rms(_ b: audio.Buffer) -> float32 {
    var sum: float32 = 0
    let lo = b.Frames / 4
    let hi = 3 * b.Frames / 4
    for i in lo..<hi {
        sum += b.Samples[i] * b.Samples[i]
    }
    return math.Sqrt(sum / float32(hi - lo))
}

let t = tone(1000, rate: 24000, seconds: 0.25)
let up = audio.Resample(t, to: 48000)
let down = audio.Resample(up, to: 24000)
var worst: float32 = 0
for i in (down.Frames / 4)..<(3 * down.Frames / 4) {
    worst = max(worst, abs(down.Samples[i] - t.Samples[i]))
}
check(up.Frames == 12000 && up.Rate == 48000, "24 kHz → 48 kHz: \(up.Frames) frames")
check(abs(rms(up) - rms(t)) < 0.002 && worst < 0.002, "a 1 kHz tone there and back: level \(rms(up)) for \(rms(t)), worst error \(worst)")

let flat = audio.Resample(audio.Buffer(samples: [float32](repeating: 0.25, count: 4800), rate: 48000), to: 22050)
var flatWorst: float32 = 0
for x in flat.Samples {
    flatWorst = max(flatWorst, abs(x - 0.25))
}
check(flat.Frames == 2205 && flatWorst < 0.0005, "a constant stays constant, edges too: 48 kHz → 22.05 kHz, worst \(flatWorst)")

let high = audio.Resample(tone(10000, rate: 48000, seconds: 0.25), to: 16000)
check(rms(high) < 0.01, "10 kHz at 48 kHz → 16 kHz is filtered, not aliased: level \(rms(high))")

let st = audio.Buffer(samples: [1, -1, 0.5, 0.25], rate: 8000, channels: 2)
check(st.Mono().Samples == [0, 0.375] && st.Channel(1) == [-1, 0.25] && st.Mono().WithChannels(2).Samples == [0, 0, 0.375, 0.375],
      "channels: mono, one channel, spread")
check(audio.PCM16(audio.Buffer(samples: [1, -1, 2, 0.5, -0.00001, -1e-12], rate: 8000)) == [32767, -32768, 32767, 16384, -1, 0], "PCM16 as libsndfile makes it: clamped, a tiny negative is 0")

print(failures == 0 ? "all passed" : "\(failures) failed")

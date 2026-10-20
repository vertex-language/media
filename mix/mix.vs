// Package mix mixes sound as it plays: voices (each a mono source with a
// gain and a place between the speakers) summed into stereo, under a
// master gain and a soft limiter, a block at a time. A voice's source is
// a function that fills a block, so a recording, a synthesizer and a
// filter chain are all voices. Changes of gain and pan glide across a
// block, so moving them every frame doesn't click.
//
//     let m = mix.Mixer(rate: 48000)
//     m.Add(mix.Tone(880, seconds: 0.2, rate: 48000))
//     out.Write(m.Render(frames: 1024))   // a media/device Output
//
// Also here: the pieces sources are built of: Biquad filters, Noise, and
// Player for an audio.Buffer.
package mix

import (
    "math"
    "media/audio"
)

/// Voice is one source in the mix.
public final class Voice {
    /// Linear gain, and where it sits: -1 left, 0 middle, 1 right.
    public var Gain: float32 = 1
    public var Pan: float32 = 0
    /// Paused voices keep their place and make no sound.
    public var Playing = true
    /// Set by the voice (or anyone) when it has finished: the mixer drops it.
    public var Done = false
    /// Frames of silence before it starts (a note later in a phrase).
    public var Wait = 0
    /// Fills its first n samples of a block (mono, -1…1); false when it
    /// has nothing more to play.
    let fill: (inout [float32], int) -> bool
    var gain: float32 = -1
    var left: float32 = 0
    var right: float32 = 0

    public init(_ fill: (inout [float32], int) -> bool) {
        self.fill = fill
    }
}

/// Mixer sums voices into interleaved stereo.
public final class Mixer {
    public let Rate: int
    /// Master gain, before the limiter.
    public var Gain: float32 = 0.8
    public private(set) var Voices: [Voice] = []
    /// The loudest sample of the last block, before the limiter.
    public private(set) var Peak: float32 = 0
    var block: [float32] = []

    public init(rate: int) { Rate = rate }

    /// Add puts a voice in the mix and answers it.
    @discardableResult
    public func Add(_ v: Voice) -> Voice {
        Voices.append(v)
        return v
    }

    /// Render makes the next `frames` frames: two samples each, left first.
    public func Render(frames: int) -> [float32] {
        var out = [float32](repeating: 0, count: frames * 2)
        if block.count < frames { block = [float32](repeating: 0, count: frames) }
        for v in Voices where v.Playing && !v.Done {
            for i in 0..<frames { block[i] = 0 }
            if v.Wait >= frames {
                v.Wait -= frames
                continue
            }
            // Starting partway into this block: fill after the wait.
            let skip = v.Wait
            v.Wait = 0
            if skip > 0 {
                var rest = [float32](repeating: 0, count: frames - skip)
                if !v.fill(&rest, frames - skip) { v.Done = true }
                for i in 0..<(frames - skip) { block[skip + i] = rest[i] }
            } else if !v.fill(&block, frames) {
                v.Done = true
            }
            // Equal-power pan; gain and pan glide from last block's to this one's.
            let p = math.Clamp(v.Pan, -1, 1)
            let a = (p + 1) * 0.25 * float32(math.Pi)
            let g = math.Max(0, v.Gain)
            let l1 = math.Cos(a) * g, r1 = math.Sin(a) * g
            if v.gain < 0 {
                v.left = l1
                v.right = r1
                v.gain = g
            }
            let l0 = v.left, r0 = v.right
            let step = 1 / float32(max(1, frames))
            var k: float32 = 0
            var o = 0
            for i in 0..<frames {
                let s = block[i]
                out[o] += s * (l0 + (l1 - l0) * k)
                out[o + 1] += s * (r0 + (r1 - r0) * k)
                k += step
                o += 2
            }
            v.left = l1
            v.right = r1
        }
        Voices.removeAll { $0.Done }
        // Master gain, then a soft knee: clean below 0.6, never past 1.
        var peak: float32 = 0
        for i in 0..<out.count {
            let x = out[i] * Gain
            let a = math.Abs(x)
            if a > peak { peak = a }
            if a > 0.6 {
                let over = (a - 0.6) / 0.4
                let y = 0.6 + 0.4 * over / (1 + over)
                out[i] = x < 0 ? -y : y
            } else {
                out[i] = x
            }
        }
        Peak = peak
        return out
    }
}

// ---- sources and the pieces of them ----

/// Noise is white noise: a fast generator, the same from the same seed.
public struct Noise {
    var state: uint32

    public init(seed: uint32 = 0x9E3779B9) { state = seed == 0 ? 1 : seed }

    /// Next is a sample, -1…1.
    public mutating func Next() -> float32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return float32(int32(bitPattern: state)) / 2147483648
    }
}

/// FilterKind is what a Biquad lets through.
public enum FilterKind {
    case lowpass
    case highpass
    case bandpass
    /// A bell: boosts (gain dB > 0) or cuts round the frequency.
    case peak
}

/// Biquad is a second-order filter (the Audio EQ Cookbook's): set its
/// kind, frequency and Q, then run samples through it one at a time.
public struct Biquad {
    var b0: float32 = 1, b1: float32 = 0, b2: float32 = 0, a1: float32 = 0, a2: float32 = 0
    var x1: float32 = 0, x2: float32 = 0, y1: float32 = 0, y2: float32 = 0

    public init() {}

    public init(_ kind: FilterKind, frequency: float32, q: float32 = 0.707, gain: float32 = 0, rate: int) {
        Set(kind, frequency: frequency, q: q, gain: gain, rate: rate)
    }

    /// Set changes what it does, keeping its state (a sweeping filter).
    public mutating func Set(_ kind: FilterKind, frequency: float32, q: float32 = 0.707, gain: float32 = 0, rate: int) {
        let f = math.Clamp(frequency, 10, float32(rate) * 0.45)
        let w = 2 * float32(math.Pi) * f / float32(rate)
        let cw = math.Cos(w), sw = math.Sin(w)
        let alpha = sw / (2 * math.Max(q, 0.05))
        var n0: float32 = 1, n1: float32 = 0, n2: float32 = 0, d0: float32 = 1, d1: float32 = 0, d2: float32 = 0
        switch kind {
        case .lowpass:
            n0 = (1 - cw) / 2; n1 = 1 - cw; n2 = (1 - cw) / 2
            d0 = 1 + alpha; d1 = -2 * cw; d2 = 1 - alpha
        case .highpass:
            n0 = (1 + cw) / 2; n1 = -(1 + cw); n2 = (1 + cw) / 2
            d0 = 1 + alpha; d1 = -2 * cw; d2 = 1 - alpha
        case .bandpass:
            n0 = alpha; n1 = 0; n2 = -alpha
            d0 = 1 + alpha; d1 = -2 * cw; d2 = 1 - alpha
        case .peak:
            let A = math.Pow(10, gain / 40)
            n0 = 1 + alpha * A; n1 = -2 * cw; n2 = 1 - alpha * A
            d0 = 1 + alpha / A; d1 = -2 * cw; d2 = 1 - alpha / A
        }
        b0 = n0 / d0; b1 = n1 / d0; b2 = n2 / d0; a1 = d1 / d0; a2 = d2 / d0
    }

    /// Run filters one sample.
    public mutating func Run(_ x: float32) -> float32 {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// Tone is a sine at a frequency for a time, with a quick rise and a
/// fall (beeps, chimes); `harmonic` adds its octave for a brighter tone.
public func Tone(_ frequency: float32, seconds: float32, rate: int, gain: float32 = 0.5, harmonic: float32 = 0.25) -> Voice {
    var phase: float32 = 0
    var t = 0
    let total = int(seconds * float32(rate))
    let attack = max(1, rate / 200)
    let release = max(1, min(total / 2, rate / 12))
    let step = frequency / float32(rate)
    let v = Voice { buf, n in
        for i in 0..<n {
            if t >= total { return false }
            var env: float32 = 1
            if t < attack { env = float32(t) / float32(attack) }
            if t > total - release { env = float32(total - t) / float32(release) }
            let s = math.Sin(phase * 2 * float32(math.Pi)) + harmonic * math.Sin(phase * 4 * float32(math.Pi))
            buf[i] = s * env * gain
            phase += step
            if phase >= 1 { phase -= 1 }
            t += 1
        }
        return true
    }
    return v
}

/// Player plays a recording: mono (a stereo buffer is mixed down), at a
/// pitch (1 as recorded, 2 an octave up; set Rate to change it while it
/// plays), once or looping.
public final class Player {
    public let Buffer: audio.Buffer
    public var Rate: float32 = 1
    public var Loop = false
    var at: float64 = 0
    let samples: [float32]
    let step: float64

    public init(_ b: audio.Buffer, mixRate: int) {
        Buffer = b
        samples = b.Channels == 1 ? b.Samples : b.Mono().Samples
        step = float64(b.Rate) / float64(mixRate)
    }

    /// Voice is the player as a voice to add to a mixer.
    public func Voice() -> mix.Voice {
        return mix.Voice { buf, n in self.fill(&buf, n) }
    }

    func fill(_ buf: inout [float32], _ n: int) -> bool {
        let count = samples.count
        if count < 2 { return false }
        for i in 0..<n {
            if at >= float64(count - 1) {
                if !Loop { return false }
                at -= float64(count - 1)
            }
            let k = int(at)
            let f = float32(at - float64(k))
            buf[i] = samples[k] + (samples[k + 1] - samples[k]) * f
            at += step * float64(Rate)
        }
        return true
    }
}

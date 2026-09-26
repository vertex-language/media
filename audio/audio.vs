// Package audio is sound in memory: a Buffer of float32 samples in
// [-1, 1], interleaved by frame, with its rate and channel count. What a
// synthesizer produces, a file format stores and a device plays is a
// Buffer; converting between rates, channel counts and integer samples
// is here, so none of them does it twice.
package audio

import (
    "math"
)

/// Buffer is interleaved float32 samples: frame 0's channels, then frame
/// 1's, and so on. A sample is nominally in [-1, 1].
public struct Buffer {
    public var Samples: [float32]
    public let Rate: int
    public let Channels: int

    /// init makes a buffer of samples already interleaved.
    public init(samples: [float32], rate: int, channels: int = 1) {
        precondition(rate > 0 && channels > 0, "audio: a buffer needs a positive rate and channel count")
        precondition(samples.count % channels == 0, "audio: \(samples.count) samples do not divide into \(channels) channels")
        self.Samples = samples
        self.Rate = rate
        self.Channels = channels
    }

    /// init makes a silent buffer of so many frames.
    public init(frames: int, rate: int, channels: int = 1) {
        self.init(samples: [float32](repeating: 0, count: frames * channels), rate: rate, channels: channels)
    }

    /// Frames is how many sample instants the buffer holds.
    public var Frames: int { return Samples.count / Channels }

    /// Seconds is the buffer's duration.
    public var Seconds: float64 { return float64(Frames) / float64(Rate) }

    /// Channel is one channel's samples.
    public func Channel(_ c: int) -> [float32] {
        precondition(c >= 0 && c < Channels, "audio: no channel \(c) in \(Channels)")
        if Channels == 1 {
            return Samples
        }
        var out = [float32](repeating: 0, count: Frames)
        for i in 0..<Frames {
            out[i] = Samples[i * Channels + c]
        }
        return out
    }

    /// Mono averages the channels into one.
    public func Mono() -> Buffer {
        if Channels == 1 {
            return self
        }
        var out = [float32](repeating: 0, count: Frames)
        let scale = 1 / float32(Channels)
        for i in 0..<Frames {
            var sum: float32 = 0
            for c in 0..<Channels {
                sum += Samples[i * Channels + c]
            }
            out[i] = sum * scale
        }
        return Buffer(samples: out, rate: Rate, channels: 1)
    }

    /// WithChannels is the buffer as so many channels: mono spread to
    /// each, or anything averaged to mono first.
    public func WithChannels(_ n: int) -> Buffer {
        if n == Channels {
            return self
        }
        let m = Mono()
        if n == 1 {
            return m
        }
        var out = [float32](repeating: 0, count: m.Frames * n)
        for i in 0..<m.Frames {
            for c in 0..<n {
                out[i * n + c] = m.Samples[i]
            }
        }
        return Buffer(samples: out, rate: Rate, channels: n)
    }

    /// Appending is this buffer followed by another of the same rate and
    /// channel count.
    public func Appending(_ b: Buffer) -> Buffer {
        precondition(b.Rate == Rate && b.Channels == Channels, "audio: appending \(b.Rate) Hz × \(b.Channels) to \(Rate) Hz × \(Channels)")
        var s = Samples
        s.append(contentsOf: b.Samples)
        return Buffer(samples: s, rate: Rate, channels: Channels)
    }

    /// Slice is frames [from, to).
    public func Slice(from: int, to: int) -> Buffer {
        precondition(from >= 0 && from <= to && to <= Frames, "audio: frames \(from)..<\(to) of \(Frames)")
        return Buffer(samples: Array(Samples[(from * Channels)..<(to * Channels)]), rate: Rate, channels: Channels)
    }

    /// Peak is the largest sample magnitude.
    public var Peak: float32 {
        var p: float32 = 0
        for s in Samples {
            let a = s < 0 ? -s : s
            if a > p {
                p = a
            }
        }
        return p
    }
}

// MARK: - Integer samples

/// PCM16 is the samples as 16-bit integers as libsndfile makes them:
/// x·2^31 rounded to 32 bits, clamped, and its top 16 bits kept.
public func PCM16(_ b: Buffer) -> [int16] {
    var out = [int16](repeating: 0, count: b.Samples.count)
    for i in 0..<b.Samples.count {
        let x = b.Samples[i]
        var v = x != x ? 0 : (float64(x) * 2147483648).rounded(.toNearestOrEven)
        v = v >= 2147483647 ? 2147483647 : (v <= -2147483648 ? -2147483648 : v)
        out[i] = int16(truncatingIfNeeded: int(v) >> 16)
    }
    return out
}

/// FromPCM16 is 16-bit integer samples as a buffer, divided by 32768 as
/// libsndfile reads them.
public func FromPCM16(_ s: [int16], rate: int, channels: int = 1) -> Buffer {
    var out = [float32](repeating: 0, count: s.count)
    for i in 0..<s.count {
        out[i] = float32(s[i]) / 32768
    }
    return Buffer(samples: out, rate: rate, channels: channels)
}

// MARK: - Resampling

/// Resample is the buffer at another rate: band-limited interpolation
/// with a Hann-windowed sinc, `taps` zero crossings each side, cut off
/// below the lower rate's Nyquist frequency so that downsampling does
/// not alias.
public func Resample(_ b: Buffer, to rate: int, taps: int = 16) -> Buffer {
    precondition(rate > 0, "audio: resampling to \(rate) Hz")
    if rate == b.Rate || b.Frames == 0 {
        return Buffer(samples: b.Samples, rate: rate, channels: b.Channels)
    }
    let ratio = float64(rate) / float64(b.Rate)
    // The filter's cutoff, as a fraction of the input's Nyquist.
    let cutoff = ratio < 1 ? ratio * 0.97 : 0.97
    let width = float64(taps) / cutoff  // input samples each side
    let frames = int((float64(b.Frames) * ratio).rounded())
    let ch = b.Channels
    var out = [float32](repeating: 0, count: frames * ch)
    let pi = 3.14159265358979323846
    for j in 0..<frames {
        let at = float64(j) / ratio  // position in input frames
        let lo = max(0, int((at - width).rounded(.up)))
        let hi = min(b.Frames - 1, int((at + width).rounded(.down)))
        if lo > hi {
            continue
        }
        var weights: [float32] = []
        weights.reserveCapacity(hi - lo + 1)
        var total: float64 = 0
        for i in lo...hi {
            let x = float64(i) - at
            var w = cutoff
            if x != 0 {
                let t = pi * x * cutoff
                w = cutoff * float64(math.Sin(float32(t))) / t
            }
            // Hann over [-width, width].
            w *= 0.5 + 0.5 * float64(math.Cos(float32(pi * x / width)))
            weights.append(float32(w))
            total += w
        }
        // Normalized, so that a constant stays that constant at the edges.
        let norm = total != 0 ? float32(1 / total) : 0
        for c in 0..<ch {
            var sum: float32 = 0
            for k in 0..<weights.count {
                sum += weights[k] * b.Samples[(lo + k) * ch + c]
            }
            out[j * ch + c] = sum * norm
        }
    }
    return Buffer(samples: out, rate: rate, channels: ch)
}

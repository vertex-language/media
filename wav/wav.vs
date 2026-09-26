// Package wav reads and writes RIFF/WAVE files: the header, a `fmt `
// chunk saying how samples are stored, and a `data` chunk holding them,
// little-endian. It writes 16, 24 and 32-bit integer PCM and 32-bit
// float; it reads those, 8-bit unsigned PCM, 64-bit float, and
// WAVE_FORMAT_EXTENSIBLE's spelling of any of them. Chunks it does not
// need (LIST, fact, PEAK, cue ...) are skipped.
//
// Integer samples scale as libsndfile's do, so a file round-trips
// through it unchanged: read as n / 2^(bits-1); written as libsndfile
// writes them, x·2^31 rounded to a 32-bit integer (clamped, so 1.0 is
// the largest) and its top bits kept.
package wav

import (
    "media/audio"
)

/// Format is how a file stores its samples.
public enum Format: Equatable {
    case pcm8     // unsigned
    case pcm16
    case pcm24
    case pcm32
    case float32
    case float64

    /// Bits is a sample's size in the file.
    public var Bits: int {
        switch self {
        case .pcm8: return 8
        case .pcm16: return 16
        case .pcm24: return 24
        case .pcm32: return 32
        case .float32: return 32
        case .float64: return 64
        }
    }

    public var IsFloat: bool { return self == .float32 || self == .float64 }
}

/// FormatError is a file this cannot read, and why.
public enum FormatError: Error, CustomStringConvertible {
    case malformed(string)
    case unsupported(string)

    public var description: string {
        switch self {
        case .malformed(let m): return "wav: malformed: \(m)"
        case .unsupported(let m): return "wav: unsupported: \(m)"
        }
    }
}

let formatPCM: int = 1
let formatFloat: int = 3
let formatExtensible: int = 0xFFFE

// MARK: - Writing

/// Encode is the buffer as a WAV file's bytes. More than two channels,
/// or samples wider than 16 bits, are written WAVE_FORMAT_EXTENSIBLE, as
/// the format's rules ask; float adds the `fact` chunk they ask for too.
public func Encode(_ b: audio.Buffer, format: Format = .pcm16) -> [uint8] {
    let bytesPer = format.Bits / 8
    let dataSize = b.Samples.count * bytesPer
    let extensible = b.Channels > 2 || (format.Bits > 16 && !format.IsFloat)
    let tag = extensible ? formatExtensible : (format.IsFloat ? formatFloat : formatPCM)
    let fmtSize = extensible ? 40 : (format.IsFloat ? 18 : 16)
    let factSize = format.IsFloat ? 12 : 0

    var w = writer()
    w.bytes.reserveCapacity(12 + 8 + fmtSize + factSize + 8 + dataSize + 1)
    w.tag("RIFF")
    w.u32(4 + 8 + fmtSize + factSize + 8 + dataSize + (dataSize & 1))
    w.tag("WAVE")

    w.tag("fmt ")
    w.u32(fmtSize)
    w.u16(tag)
    w.u16(b.Channels)
    w.u32(b.Rate)
    w.u32(b.Rate * b.Channels * bytesPer)
    w.u16(b.Channels * bytesPer)
    w.u16(format.Bits)
    if fmtSize > 16 {
        w.u16(fmtSize - 18)  // cbSize: 22 for extensible, 0 for plain float
    }
    if extensible {
        w.u16(format.Bits)                    // valid bits
        w.u32(channelMask(b.Channels))
        w.u16(format.IsFloat ? formatFloat : formatPCM)  // the GUID's first two bytes
        w.bytes.append(contentsOf: subformatTail)
    }
    if format.IsFloat {
        w.tag("fact")
        w.u32(4)
        w.u32(b.Frames)
    }

    w.tag("data")
    w.u32(dataSize)
    for x in b.Samples {
        switch format {
        case .pcm8:
            w.bytes.append(uint8(quantize(x, bits: 8) + 128))
        case .pcm16:
            w.u16(quantize(x, bits: 16) & 0xFFFF)
        case .pcm24:
            let v = quantize(x, bits: 24)
            w.bytes.append(uint8(truncatingIfNeeded: v))
            w.bytes.append(uint8(truncatingIfNeeded: v >> 8))
            w.bytes.append(uint8(truncatingIfNeeded: v >> 16))
        case .pcm32:
            w.u32(quantize(x, bits: 32) & 0xFFFF_FFFF)
        case .float32:
            w.u32(int(x.bitPattern))
        case .float64:
            let v = float64(x).bitPattern
            w.u32(int(v & 0xFFFF_FFFF))
            w.u32(int(v >> 32))
        }
    }
    if dataSize & 1 == 1 {
        w.bytes.append(0)  // chunks are padded to even sizes
    }
    return w.bytes
}

// The KSDATAFORMAT_SUBTYPE GUID after its first two bytes:
// {0000000x-0000-0010-8000-00aa00389b71}.
let subformatTail: [uint8] = [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]

// channelMask is the speaker positions libsndfile gives n channels.
func channelMask(_ n: int) -> int {
    switch n {
    case 1: return 0x4        // front center
    case 2: return 0x3        // front left, right
    case 4: return 0x33       // front and back, left and right
    case 6: return 0x3F       // 5.1
    case 8: return 0x63F      // 7.1
    default: return 0
    }
}

// quantize is a sample as a signed integer of so many bits, as
// libsndfile makes it: rint(x·2^31), clamped to 32 bits, shifted down
// arithmetically, so narrower formats floor what the 32-bit one rounds.
// A float32 times a power of two is exact in float64.
func quantize(_ x: float32, bits: int) -> int {
    return pcm32(x) >> (32 - bits)
}

func pcm32(_ x: float32) -> int {
    if x != x {
        return 0
    }
    let v = (float64(x) * 2147483648).rounded(.toNearestOrEven)
    if v >= 2147483647 {
        return 2147483647
    }
    if v <= -2147483648 {
        return -2147483648
    }
    return int(v)
}

struct writer {
    var bytes: [uint8] = []

    mutating func tag(_ s: string) {
        bytes.append(contentsOf: Array(s.utf8))
    }

    mutating func u16(_ v: int) {
        bytes.append(uint8(truncatingIfNeeded: v))
        bytes.append(uint8(truncatingIfNeeded: v >> 8))
    }

    mutating func u32(_ v: int) {
        bytes.append(uint8(truncatingIfNeeded: v))
        bytes.append(uint8(truncatingIfNeeded: v >> 8))
        bytes.append(uint8(truncatingIfNeeded: v >> 16))
        bytes.append(uint8(truncatingIfNeeded: v >> 24))
    }
}

// MARK: - Reading

/// Info is what a file's `fmt ` chunk says.
public struct Info {
    public let Format: Format
    public let Rate: int
    public let Channels: int
    public let Frames: int
}

/// Decode reads a WAV file's bytes into a buffer, along with how the
/// file stored them.
public func Decode(_ bytes: [uint8]) throws -> (audio.Buffer, Info) {
    var r = reader(bytes: bytes)
    guard bytes.count >= 12, r.tag(0) == "RIFF", r.tag(8) == "WAVE" else {
        throw FormatError.malformed("not a RIFF/WAVE file")
    }
    var at = 12
    var format: Format? = nil
    var channels = 0
    var rate = 0
    var blockAlign = 0
    var dataAt = -1
    var dataSize = 0
    while at + 8 <= bytes.count {
        let id = r.tag(at)
        var size = r.u32(at + 4)
        let body = at + 8
        if body + size > bytes.count {
            // A writer that never came back to fix its sizes (a stream)
            // leaves them too big, or 0xFFFFFFFF; the data runs to the end.
            if id != "data" {
                throw FormatError.malformed("the \(id) chunk runs past the end of the file")
            }
            size = bytes.count - body
        }
        if id == "fmt " {
            if size < 16 {
                throw FormatError.malformed("a fmt chunk of \(size) bytes")
            }
            var tag = r.u16(body)
            channels = r.u16(body + 2)
            rate = r.u32(body + 4)
            blockAlign = r.u16(body + 12)
            let bits = r.u16(body + 14)
            if tag == formatExtensible {
                if size < 40 {
                    throw FormatError.malformed("an extensible fmt chunk of \(size) bytes")
                }
                tag = r.u16(body + 24)
            }
            switch (tag, bits) {
            case (formatPCM, 8): format = .pcm8
            case (formatPCM, 16): format = .pcm16
            case (formatPCM, 24): format = .pcm24
            case (formatPCM, 32): format = .pcm32
            case (formatFloat, 32): format = .float32
            case (formatFloat, 64): format = .float64
            default:
                throw FormatError.unsupported("format tag \(tag) with \(bits)-bit samples")
            }
        } else if id == "data" {
            dataAt = body
            dataSize = size
            break
        }
        at = body + size + (size & 1)
    }
    guard let f = format else {
        throw FormatError.malformed("no fmt chunk before the data")
    }
    if dataAt < 0 {
        throw FormatError.malformed("no data chunk")
    }
    if channels < 1 || rate < 1 || blockAlign != channels * f.Bits / 8 {
        throw FormatError.malformed("\(channels) channels at \(rate) Hz, \(blockAlign)-byte frames of \(f.Bits)-bit samples")
    }
    let frames = dataSize / blockAlign
    let n = frames * channels
    var out = [float32](repeating: 0, count: n)
    var p = dataAt
    switch f {
    case .pcm8:
        for i in 0..<n {
            out[i] = float32(int(bytes[p + i]) - 128) / 128
        }
    case .pcm16:
        for i in 0..<n {
            out[i] = float32(int16(truncatingIfNeeded: r.u16(p))) / 32768
            p += 2
        }
    case .pcm24:
        for i in 0..<n {
            var v = int(bytes[p]) | int(bytes[p + 1]) << 8 | int(bytes[p + 2]) << 16
            if v >= 0x800000 {
                v -= 0x1000000
            }
            out[i] = float32(v) / 8388608
            p += 3
        }
    case .pcm32:
        for i in 0..<n {
            out[i] = float32(float64(int32(truncatingIfNeeded: r.u32(p))) / 2147483648)
            p += 4
        }
    case .float32:
        for i in 0..<n {
            out[i] = float32(bitPattern: uint32(r.u32(p)))
            p += 4
        }
    case .float64:
        for i in 0..<n {
            let v = uint64(r.u32(p)) | uint64(r.u32(p + 4)) << 32
            out[i] = float32(float64(bitPattern: v))
            p += 8
        }
    }
    return (audio.Buffer(samples: out, rate: rate, channels: channels),
            Info(Format: f, Rate: rate, Channels: channels, Frames: frames))
}

struct reader {
    let bytes: [uint8]

    func tag(_ at: int) -> string {
        return string(decoding: bytes[at..<(at + 4)], as: UTF8.self)
    }

    func u16(_ at: int) -> int {
        return int(bytes[at]) | int(bytes[at + 1]) << 8
    }

    func u32(_ at: int) -> int {
        return int(bytes[at]) | int(bytes[at + 1]) << 8 | int(bytes[at + 2]) << 16 | int(bytes[at + 3]) << 24
    }
}

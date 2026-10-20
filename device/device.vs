// Package device plays sound: an Output the system pulls frames from on
// its own thread while the program writes them ahead. Writing copies
// into a ring and never waits, so a game writes what its next frame or
// two will need each frame and the sound keeps going between them.
//
//     let out = try device.Output.Open(rate: 48000, channels: 2)
//     defer out.Close()
//     _ = out.Write(samples)   // interleaved float32, -1…1
//
// macOS: the default output AudioUnit. Elsewhere Open throws
// unsupported for now (WASAPI and AAudio are next).
package device

import (
    "media/audio"
)

/// DeviceError is why an output didn't open.
public enum DeviceError: Error {
    /// This system has no output this package can drive yet.
    case unsupported
    /// Too many outputs open.
    case busy
    /// The system refused (its code).
    case failed(int32)
}

/// Output is a stream of frames to the default output device.
public final class Output {
    let handle: int32
    /// Frames a second, and samples a frame.
    public let Rate: int
    public let Channels: int
    /// The most frames that can wait to be played.
    public let Capacity: int
    var closed = false

    init(_ handle: int32, rate: int, channels: int, capacity: int) {
        self.handle = handle
        Rate = rate
        Channels = channels
        Capacity = capacity
    }

    /// Open starts a stream at a rate and channel count, with room for
    /// `seconds` of frames waiting.
    public static func Open(rate: int = 48000, channels: int = 2, seconds: float64 = 0.5) throws -> Output {
        let capacity = max(256, int(float64(rate) * seconds))
        let h = outputOpen(int32(rate), int32(channels), int32(capacity))
        if h == Code.unsupported { throw DeviceError.unsupported }
        if h == Code.full { throw DeviceError.busy }
        if h <= 0 { throw DeviceError.failed(h) }
        return Output(h, rate: rate, channels: channels, capacity: capacity)
    }

    /// Write queues interleaved frames (Channels samples each) and answers
    /// how many frames it took: fewer when the queue is nearly full.
    @discardableResult
    public func Write(_ samples: [float32]) -> int {
        if closed || samples.isEmpty { return 0 }
        let frames = samples.count / Channels
        let n = samples.withUnsafeBufferPointer { p in outputWrite(handle, p.baseAddress, int32(frames)) }
        return n > 0 ? int(n) : 0
    }

    /// Write queues a buffer's frames (it must have this stream's rate and
    /// channels).
    @discardableResult
    public func Write(_ b: audio.Buffer) -> int {
        return Write(b.Samples)
    }

    /// Queued is how many frames wait to be played.
    public var Queued: int {
        if closed { return 0 }
        let n = outputQueued(handle)
        return n > 0 ? int(n) : 0
    }

    /// Underruns is how many times the device found nothing to play since
    /// it started (each a short gap of silence).
    public var Underruns: int {
        if closed { return 0 }
        let n = outputUnderruns(handle)
        return n > 0 ? int(n) : 0
    }

    /// Close stops the stream.
    public func Close() {
        if closed { return }
        closed = true
        _ = outputClose(handle)
    }

    deinit { Close() }
}

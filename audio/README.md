# media/audio

Sound in memory: a Buffer of float32 samples in [-1, 1], interleaved by frame, with its rate and channel count.

```vertex
import "media/audio"
```

## Types

- **`Buffer`** (struct): Buffer is interleaved float32 samples: frame 0's channels, then frame 1's, and so on. A sample is nominally in [-1, 1].

## Functions

- `func PCM16(_ b: Buffer) -> [int16]`: PCM16 is the samples as 16-bit integers as libsndfile makes them: x·2^31 rounded to 32 bits, clamped, and its top 16 bits kept.
- `func FromPCM16(_ s: [int16], rate: int, channels: int = 1) -> Buffer`: FromPCM16 is 16-bit integer samples as a buffer, divided by 32768 as libsndfile reads them.
- `func Resample(_ b: Buffer, to rate: int, taps: int = 16) -> Buffer`: Resample is the buffer at another rate: band-limited interpolation with a Hann-windowed sinc, `taps` zero crossings each side, cut off below the lower rate's Nyquist frequency so that downsampling does not alias.

Part of the [`media`](https://github.com/vertex-language/media) repository.

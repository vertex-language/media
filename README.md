# media

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)

Sound in memory, in files and (next) out of the speakers. What a synthesizer produces, a file stores and a device plays is one `audio.Buffer`.

---

## Quick Start

```bash
vsc run test-wav    # every WAV format against libsndfile, and the resampler
```

---

## Packages

| Package | What it is |
| --- | --- |
| **`media/audio`** | `audio.Buffer`: interleaved float32 samples with a rate and channel count. `Mono`, `WithChannels`, `Channel`, `Slice`, `Appending`, `Peak`; `audio.Resample(b, to: rate)` (Hann-windowed sinc, anti-aliased when downsampling); `audio.PCM16` / `FromPCM16` |
| **`media/wav`** | `wav.Encode(buffer, format: .pcm16)` and `wav.Decode(bytes)`: RIFF/WAVE in pure Vertex. Writes 16/24/32-bit PCM and 32-bit float (WAVE_FORMAT_EXTENSIBLE where the format asks for it); reads those, 8-bit PCM, 64-bit float and extensible files. Samples convert as libsndfile converts them, bit for bit |

Planned: `media/device` (playback: AudioUnit on macOS, WASAPI, AAudio).

---

## Testing

`testdata/oracle/wav_oracle.py` is the reference: libsndfile, through Python's `soundfile`. `make` writes the fixtures in `testdata/wav`; after `vsc run test-wav`, `check testdata/out` reads back what `media/wav` wrote.

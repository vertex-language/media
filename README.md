# media

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)

Sound in memory, in files, mixed as it plays, and out of the speakers. What a synthesizer produces, a file stores and a device plays is one `audio.Buffer`.

---

## Quick Start

```bash
vsc run test-wav    # every WAV format against libsndfile, and the resampler
vsc run check-mix   # tones at their pitch and pan, the limiter, filters, players; a busy second's cost
vsc run play-tone   # a chord out of the speakers (needs a sound device)
```

---

## Packages

| Package | What it is |
| --- | --- |
| **`media/audio`** | `audio.Buffer`: interleaved float32 samples with a rate and channel count. `Mono`, `WithChannels`, `Channel`, `Slice`, `Appending`, `Peak`; `audio.Resample(b, to: rate)` (Hann-windowed sinc, anti-aliased when downsampling); `audio.PCM16` / `FromPCM16` |
| **`media/wav`** | `wav.Encode(buffer, format: .pcm16)` and `wav.Decode(bytes)`: RIFF/WAVE in pure Vertex. Writes 16/24/32-bit PCM and 32-bit float (WAVE_FORMAT_EXTENSIBLE where the format asks for it); reads those, 8-bit PCM, 64-bit float and extensible files. Samples convert as libsndfile converts them, bit for bit |

| **`media/mix`** | `Mixer`: voices (a mono source as a function that fills a block, a gain, a pan) summed into interleaved stereo a block at a time, gains and pans gliding across each block, a master gain and a soft limiter; finished voices drop out. The pieces of sources: `Biquad` (lowpass, highpass, bandpass, peak), `Noise`, `Tone` (beeps and chimes), `Player` (an `audio.Buffer` at any pitch, once or looping) |
| **`media/device`** | `Output`: a stream to the default output device. `Write` copies interleaved frames into a ring the system plays from on its own thread and never waits; `Queued`, `Underruns`, `Close`. Native: an AudioUnit on macOS (`device_darwin.mm`); WASAPI and AAudio next |

---

## Testing

`testdata/oracle/wav_oracle.py` is the reference: libsndfile, through Python's `soundfile`. `make` writes the fixtures in `testdata/wav`; after `vsc run test-wav`, `check testdata/out` reads back what `media/wav` wrote.

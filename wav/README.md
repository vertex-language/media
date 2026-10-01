# media/wav

Reads and writes RIFF/WAVE files: the header, a `fmt ` chunk saying how samples are stored, and a `data` chunk holding them, little-endian.

```vertex
import "media/wav"
```

## Types

- **`Format`** (enum): Format is how a file stores its samples.
- **`FormatError`** (enum): FormatError is a file this cannot read, and why.
- **`Info`** (struct): Info is what a file's `fmt ` chunk says.

## Functions

- `func Encode(_ b: audio.Buffer, format: Format = .pcm16) -> [uint8]`: Encode is the buffer as a WAV file's bytes.
- `func Decode(_ bytes: [uint8]) throws -> (audio.Buffer, Info)`: Decode reads a WAV file's bytes into a buffer, along with how the file stored them.

Part of the [`media`](https://github.com/vertex-language/media) repository.

# The WAV oracle is libsndfile, through soundfile.
#
#   wav_oracle.py make      writes testdata/wav: signal.f32 (the float32
#                           samples every fixture holds), a fixture per
#                           format and channel count as libsndfile writes
#                           it, and beside each the .f32 it reads back
#   wav_oracle.py check D   reads every .wav media/wav wrote into D and
#                           prints its format, rate, shape and whether its
#                           samples match D's .f32 of what was encoded
import sys, os, numpy as np, soundfile as sf

here = os.path.join(os.path.dirname(__file__), "..", "wav")
subtypes = {"pcm8": "PCM_U8", "pcm16": "PCM_16", "pcm24": "PCM_24",
            "pcm32": "PCM_32", "float32": "FLOAT", "float64": "DOUBLE"}

def signal(channels, rate=24000, frames=1200):
    t = np.arange(frames) / rate
    cols = []
    for c in range(channels):
        # a tone, a chirp, and a stretch past full scale that has to clip
        x = 0.6 * np.sin(2 * np.pi * (220 * (c + 1)) * t) + 0.3 * np.sin(2 * np.pi * (500 + 4000 * t) * t)
        x[200:260] *= 2.5
        x[300] = 1.0
        x[301] = -1.0
        cols.append(x)
    return np.stack(cols, axis=1).astype(np.float32)

def make():
    os.makedirs(here, exist_ok=True)
    for ch in (1, 2, 3):
        s = signal(ch)
        s.tofile(os.path.join(here, f"signal{ch}.f32"))
        for name, sub in subtypes.items():
            p = os.path.join(here, f"{name}-{ch}ch.wav")
            sf.write(p, s, 24000, subtype=sub, format="WAV")
            back, _ = sf.read(p, dtype="float32", always_2d=True)
            back.tofile(p[:-4] + ".f32")

def check(d):
    for n in sorted(os.listdir(d)):
        if not n.endswith(".wav"):
            continue
        p = os.path.join(d, n)
        info = sf.info(p)
        got, rate = sf.read(p, dtype="float32", always_2d=True)
        want = np.fromfile(p[:-4] + ".f32", dtype=np.float32).reshape(got.shape) if os.path.exists(p[:-4] + ".f32") else None
        same = want is not None and np.array_equal(got, want)
        print(n, info.format, info.subtype, rate, "x".join(map(str, got.shape)), "same" if same else "DIFFERENT")

if __name__ == "__main__":
    if sys.argv[1] == "make":
        make()
    else:
        check(sys.argv[2])

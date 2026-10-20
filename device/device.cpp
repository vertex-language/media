// Real-time audio out, for package media/device: an output stream the
// system pulls from on its own thread, fed by the program through a ring
// of interleaved float32 frames. Writing copies into the ring and never
// waits; the system's callback reads from it and plays silence when it
// runs dry (an underrun), counting each time. macOS's is an AudioUnit
// (device_darwin.cpp); elsewhere there is none yet.
module;
#include <stdint.h>
#if defined(__APPLE__)
#pragma vertex framework("AudioToolbox")
#pragma vertex framework("AudioUnit")
#pragma vertex framework("CoreAudio")
#endif
export module media.device;

export namespace Code {
    constexpr int32_t ok = 0, generic = -1, unsupported = -2, full = -3, badHandle = -4;
}

// outputOpen opens the default output at a rate with a channel count and
// a ring of capacity frames. Answers a handle (> 0) or a negative code.
export int32_t outputOpen(int32_t rate, int32_t channels, int32_t capacity) noexcept;

// outputWrite copies up to frames interleaved frames into the ring.
// Answers how many it took (fewer when the ring is nearly full).
export int32_t outputWrite(int32_t handle, const float* samples, int32_t frames) noexcept;

// outputQueued is how many frames wait in the ring, not yet played.
export int32_t outputQueued(int32_t handle) noexcept;

// outputUnderruns is how many times the system found the ring empty
// since the stream started playing.
export int32_t outputUnderruns(int32_t handle) noexcept;

// outputRate is the rate the stream runs at.
export int32_t outputRate(int32_t handle) noexcept;

// outputClose stops the stream and frees it.
export int32_t outputClose(int32_t handle) noexcept;

#if !defined(__APPLE__)
int32_t outputOpen(int32_t, int32_t, int32_t) noexcept { return Code::unsupported; }
int32_t outputWrite(int32_t, const float*, int32_t) noexcept { return Code::unsupported; }
int32_t outputQueued(int32_t) noexcept { return Code::unsupported; }
int32_t outputUnderruns(int32_t) noexcept { return Code::unsupported; }
int32_t outputRate(int32_t) noexcept { return Code::unsupported; }
int32_t outputClose(int32_t) noexcept { return Code::unsupported; }
#endif

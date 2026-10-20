// The output stream on macOS: the default output AudioUnit, its render
// callback reading a ring the program writes. The ring's counts are
// guarded by an unfair lock held only to copy; the callback only tries
// it, so it never waits on the program (a miss plays one buffer of
// silence). See device.cpp.
module;
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <os/lock.h>
#include <AudioToolbox/AudioToolbox.h>
module media.device;

namespace {

struct Stream {
    AudioComponentInstance unit = nullptr;
    float* ring = nullptr;
    int32_t capacity = 0;   // frames
    int32_t channels = 0;
    int32_t rate = 0;
    // Frames ever written and read; the ring index is the count modulo
    // capacity. Only the writer moves written, only the callback read.
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    int64_t written = 0;
    int64_t read = 0;
    int32_t underruns = 0;
    bool started = false;
    bool used = false;
};

constexpr int32_t maxStreams = 8;
Stream streams[maxStreams];

Stream* find(int32_t handle) {
    if (handle < 1 || handle > maxStreams) return nullptr;
    Stream* s = &streams[handle - 1];
    return s->used ? s : nullptr;
}

OSStatus render(void* ref, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames,
                AudioBufferList* io) {
    Stream* s = static_cast<Stream*>(ref);
    float* out = static_cast<float*>(io->mBuffers[0].mData);
    const int32_t ch = s->channels;
    if (!os_unfair_lock_trylock(&s->lock)) {
        memset(out, 0, (size_t)frames * ch * sizeof(float));
        return noErr;
    }
    const int64_t r = s->read;
    const int64_t w = s->written;
    int64_t n = w - r;
    if (n > (int64_t)frames) n = frames;
    if (n < 0) n = 0;
    for (int64_t i = 0; i < n; i++) {
        const int64_t at = ((r + i) % s->capacity) * ch;
        for (int32_t c = 0; c < ch; c++) out[i * ch + c] = s->ring[at + c];
    }
    if (n < (int64_t)frames) {
        memset(out + n * ch, 0, (size_t)((int64_t)frames - n) * ch * sizeof(float));
        if (s->started) s->underruns++;
    }
    if (n > 0) s->started = true;
    s->read = r + n;
    os_unfair_lock_unlock(&s->lock);
    return noErr;
}

}  // namespace

int32_t outputOpen(int32_t rate, int32_t channels, int32_t capacity) noexcept {
    if (rate < 8000 || rate > 192000 || channels < 1 || channels > 8 || capacity < 64) return Code::generic;
    int32_t slot = -1;
    for (int32_t i = 0; i < maxStreams; i++) {
        if (!streams[i].used) { slot = i; break; }
    }
    if (slot < 0) return Code::full;
    Stream* s = &streams[slot];
    AudioComponentDescription d = {};
    d.componentType = kAudioUnitType_Output;
    d.componentSubType = kAudioUnitSubType_DefaultOutput;
    d.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(nullptr, &d);
    if (comp == nullptr) return Code::unsupported;
    AudioComponentInstance unit = nullptr;
    if (AudioComponentInstanceNew(comp, &unit) != noErr || unit == nullptr) return Code::unsupported;

    AudioStreamBasicDescription f = {};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = (UInt32)channels;
    f.mBitsPerChannel = 32;
    f.mBytesPerFrame = 4 * (UInt32)channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = f.mBytesPerFrame;
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr) {
        AudioComponentInstanceDispose(unit);
        return Code::generic;
    }
    s->ring = static_cast<float*>(calloc((size_t)capacity * channels, sizeof(float)));
    if (s->ring == nullptr) {
        AudioComponentInstanceDispose(unit);
        return Code::generic;
    }
    s->capacity = capacity;
    s->channels = channels;
    s->rate = rate;
    s->lock = OS_UNFAIR_LOCK_INIT;
    s->written = 0;
    s->read = 0;
    s->underruns = 0;
    s->started = false;
    AURenderCallbackStruct cb = {};
    cb.inputProc = render;
    cb.inputProcRefCon = s;
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr ||
        AudioUnitInitialize(unit) != noErr) {
        AudioComponentInstanceDispose(unit);
        free(s->ring);
        s->ring = nullptr;
        return Code::generic;
    }
    s->unit = unit;
    s->used = true;
    if (AudioOutputUnitStart(unit) != noErr) {
        outputClose(slot + 1);
        return Code::generic;
    }
    return slot + 1;
}

int32_t outputWrite(int32_t handle, const float* samples, int32_t frames) noexcept {
    Stream* s = find(handle);
    if (s == nullptr) return Code::badHandle;
    if (samples == nullptr || frames <= 0) return 0;
    os_unfair_lock_lock(&s->lock);
    const int64_t w = s->written;
    const int64_t r = s->read;
    int64_t room = s->capacity - (w - r);
    int64_t n = frames < room ? frames : room;
    const int32_t ch = s->channels;
    for (int64_t i = 0; i < n; i++) {
        const int64_t at = ((w + i) % s->capacity) * ch;
        for (int32_t c = 0; c < ch; c++) s->ring[at + c] = samples[i * ch + c];
    }
    s->written = w + n;
    os_unfair_lock_unlock(&s->lock);
    return (int32_t)n;
}

int32_t outputQueued(int32_t handle) noexcept {
    Stream* s = find(handle);
    if (s == nullptr) return Code::badHandle;
    os_unfair_lock_lock(&s->lock);
    const int64_t n = s->written - s->read;
    os_unfair_lock_unlock(&s->lock);
    return (int32_t)n;
}

int32_t outputUnderruns(int32_t handle) noexcept {
    Stream* s = find(handle);
    if (s == nullptr) return Code::badHandle;
    return s->underruns;
}

int32_t outputRate(int32_t handle) noexcept {
    Stream* s = find(handle);
    if (s == nullptr) return Code::badHandle;
    return s->rate;
}

int32_t outputClose(int32_t handle) noexcept {
    Stream* s = find(handle);
    if (s == nullptr) return Code::badHandle;
    if (s->unit != nullptr) {
        AudioOutputUnitStop(s->unit);
        AudioUnitUninitialize(s->unit);
        AudioComponentInstanceDispose(s->unit);
        s->unit = nullptr;
    }
    free(s->ring);
    s->ring = nullptr;
    s->used = false;
    return Code::ok;
}

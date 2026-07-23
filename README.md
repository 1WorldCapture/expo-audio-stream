# @1worldcapture/expo-audio-stream

This is the 1WorldCapture-maintained fork used by Qwen Realtime App. Release
`1.0.1-1worldcapture.0` keeps the upstream 1.0.0 audio behavior and adds Expo
SDK 57 / React Native 0.86 Android compatibility. The native module and
JavaScript API remain backward-compatible with the upstream package.

Native audio recording and low-latency playback for Expo/React Native. Designed for real-time voice AI applications: microphone capture, chunked PCM playback, and a jitter-buffered native pipeline for streaming audio from AI backends.

## Install

```bash
npm install @1worldcapture/expo-audio-stream@github:1WorldCapture/expo-audio-stream#v1.0.1-1worldcapture.0
```

## Quick Start

### Microphone Recording

```typescript
import { ExpoPlayAudioStream } from "@1worldcapture/expo-audio-stream";

const { recordingResult, subscription } =
  await ExpoPlayAudioStream.startMicrophone({
    sampleRate: 16000,
    channels: 1,
    encoding: "pcm_16bit",
    interval: 100,
    onAudioStream: async (event) => {
      // event.data: base64-encoded PCM chunk
      // event.soundLevel: current mic level (dB)
      // event.frequencyBands: { low, mid, high } (0–1) if configured
      sendToBackend(event.data);
    },
    frequencyBandConfig: {
      lowCrossoverHz: 300,
      highCrossoverHz: 2000,
    },
  });

// Later:
await ExpoPlayAudioStream.stopMicrophone();
subscription?.remove();
```

### Chunked Playback (playSound)

For playing base64-encoded PCM audio in a queue with turn management:

```typescript
import {
  ExpoPlayAudioStream,
  EncodingTypes,
} from "@1worldcapture/expo-audio-stream";

await ExpoPlayAudioStream.setSoundConfig({
  sampleRate: 24000,
  playbackMode: "conversation",
});

// Enqueue chunks as they arrive
await ExpoPlayAudioStream.playSound(
  base64Chunk,
  "turn-1",
  EncodingTypes.PCM_S16LE
);

// Listen for playback completion
const sub = ExpoPlayAudioStream.subscribeToSoundChunkPlayed(async (e) => {
  if (e.isFinal) console.log("Turn finished playing");
});
```

### Native Pipeline (recommended for AI voice streaming)

The `Pipeline` class provides jitter-buffered, low-latency playback with a native write thread. Use this for streaming audio from AI backends over WebSockets.

```typescript
import { Pipeline } from "@1worldcapture/expo-audio-stream";

// Connect with desired config
const result = await Pipeline.connect({
  sampleRate: 24000,
  channelCount: 1,
  targetBufferMs: 80,
  frequencyBandIntervalMs: 100, // optional: emit frequency bands every 100ms
  audioMode: "mixWithOthers",   // coexist with other apps (default)
});

// Subscribe to events
const errorSub = Pipeline.onError((err) => {
  console.error(`Pipeline error: ${err.code} - ${err.message}`);
});

const focusSub = Pipeline.onAudioFocus(({ focused }) => {
  if (!focused) {
    // Another app took audio focus; re-request audio on regain
  }
});

// Hot path: push audio synchronously from WebSocket handler
ws.onmessage = (msg) => {
  Pipeline.pushAudioSync({
    audio: msg.data, // base64 PCM16 LE
    turnId: currentTurnId,
    isFirstChunk: isFirst,
    isLastChunk: isLast,
  });
};

// On new turn, invalidate stale audio
Pipeline.invalidateTurn({ turnId: newTurnId });

// Tear down
await Pipeline.disconnect();
errorSub.remove();
focusSub.remove();
```

## API Reference

### ExpoPlayAudioStream

All methods are static.

#### Lifecycle

| Method | Returns | Description |
|--------|---------|-------------|
| `destroy()` | `void` | Release all resources. Resets internal state on both platforms. |

#### Permissions

| Method | Returns | Description |
|--------|---------|-------------|
| `requestPermissionsAsync()` | `Promise<PermissionResult>` | Prompt the user for microphone permission. |
| `getPermissionsAsync()` | `Promise<PermissionResult>` | Check the current microphone permission status. |

#### Microphone

| Method | Returns | Description |
|--------|---------|-------------|
| `startMicrophone(config)` | `Promise<{ recordingResult, subscription? }>` | Start mic capture. Audio is delivered as base64 PCM via `onAudioStream` or `subscribeToAudioEvents`. |
| `stopMicrophone()` | `Promise<AudioRecording \| null>` | Stop mic capture and return recording metadata. |
| `toggleSilence(isSilent)` | `void` | Mute/unmute the mic stream without stopping the session. Silenced frames are zero-filled. |
| `promptMicrophoneModes()` | `void` | (iOS only) Show the system voice isolation picker (iOS 15+). |

#### Sound Playback

| Method | Returns | Description |
|--------|---------|-------------|
| `playSound(audio, turnId, encoding?)` | `Promise<void>` | Enqueue a base64 PCM chunk for playback. |
| `stopSound()` | `Promise<void>` | Stop playback and clear the queue. |
| `setSoundConfig(config)` | `Promise<void>` | Update playback sample rate and mode. |

#### Event Subscriptions

| Method | Returns | Description |
|--------|---------|-------------|
| `subscribeToAudioEvents(callback)` | `Subscription` | Receive `AudioDataEvent` during mic capture. |
| `subscribeToSoundChunkPlayed(callback)` | `Subscription` | Notified when a chunk finishes playing. `isFinal` is true when the queue drains. |
| `subscribe(eventName, callback)` | `Subscription` | Generic event listener for any module event. |

### Pipeline

All methods are static. The pipeline manages its own native write thread, jitter buffer, and audio focus.

#### Lifecycle

| Method | Returns | Description |
|--------|---------|-------------|
| `connect(options?)` | `Promise<ConnectPipelineResult>` | Create the native audio track, jitter buffer, and write thread. Config is immutable per session. |
| `disconnect()` | `Promise<void>` | Tear down the pipeline and release all native resources. |

#### Audio Push

| Method | Returns | Description |
|--------|---------|-------------|
| `pushAudio(options)` | `Promise<void>` | Push base64 PCM16 LE audio (async, with error propagation). |
| `pushAudioSync(options)` | `boolean` | Push audio synchronously. No Promise overhead -- use in WebSocket `onmessage` for minimum latency. Returns `false` on failure. |

#### Turn Management

| Method | Returns | Description |
|--------|---------|-------------|
| `invalidateTurn(options)` | `Promise<void>` | Discard buffered audio for the old turn. The jitter buffer is reset. |

#### State & Telemetry

| Method | Returns | Description |
|--------|---------|-------------|
| `getState()` | `PipelineState` | Current state: `idle`, `connecting`, `streaming`, `draining`, or `error`. |
| `getTelemetry()` | `PipelineTelemetry` | Snapshot of buffer levels, push counts, write loops, underruns, etc. |

#### Event Subscriptions

| Method | Returns | Description |
|--------|---------|-------------|
| `subscribe(eventName, listener)` | `EventSubscription` | Type-safe subscription to any pipeline event. |
| `onError(listener)` | `{ remove }` | Convenience: handles both `PipelineError` and `PipelineZombieDetected`. |
| `onAudioFocus(listener)` | `{ remove }` | Convenience: `{ focused: true/false }` on audio focus changes. |

## Configuration Types

### RecordingConfig

```typescript
interface RecordingConfig {
  sampleRate?: 16000 | 24000 | 44100 | 48000;
  channels?: 1 | 2;
  encoding?: "pcm_32bit" | "pcm_16bit" | "pcm_8bit";
  interval?: number; // ms between audio data emissions (default 1000)
  onAudioStream?: (event: AudioDataEvent) => Promise<void>;
  frequencyBandConfig?: FrequencyBandConfig; // enable frequency band analysis on mic audio
}
```

### SoundConfig

```typescript
interface SoundConfig {
  sampleRate?: 16000 | 24000 | 44100 | 48000;
  playbackMode?: "regular" | "voiceProcessing" | "conversation";
  useDefault?: boolean; // reset to defaults
}
```

### ConnectPipelineOptions

```typescript
interface ConnectPipelineOptions {
  sampleRate?: number;              // default 24000
  channelCount?: number;            // default 1 (mono)
  targetBufferMs?: number;          // ms to buffer before priming gate opens (default 80)
  playbackMode?: "voiceProcessing" | "conversation";
  frequencyBandIntervalMs?: number; // emit PipelineFrequencyBands every N ms (omit to disable)
  frequencyBandConfig?: FrequencyBandConfig; // crossover frequencies (optional)
  audioMode?: "mixWithOthers" | "duckOthers" | "doNotMix"; // default "mixWithOthers"
}
```

#### `audioMode`

Controls how pipeline playback coexists with audio from other apps on the device. Default: `"mixWithOthers"` (matches expo-audio).

- **`"mixWithOthers"`** — plays alongside other apps without interrupting them. On Android no audio focus is requested; on iOS the session uses the `.mixWithOthers` category option. Best for sound effects and short clips.
- **`"duckOthers"`** — requests audio focus with ducking. Other apps lower their volume but keep playing.
- **`"doNotMix"`** — requests exclusive audio focus. Other apps pause.

> **Breaking change:** The default was effectively `"doNotMix"` in prior versions. If you rely on the previous behavior — where connecting the pipeline pauses other apps' audio — pass `audioMode: "doNotMix"` explicitly when calling `Pipeline.connect`.

### PushPipelineAudioOptions

```typescript
interface PushPipelineAudioOptions {
  audio: string;           // base64-encoded PCM 16-bit signed LE
  turnId: string;
  isFirstChunk?: boolean;  // resets jitter buffer
  isLastChunk?: boolean;   // marks end-of-stream, begins drain
}
```

### FrequencyBandConfig

```typescript
interface FrequencyBandConfig {
  lowCrossoverHz?: number;  // boundary between low and mid bands (default 300)
  highCrossoverHz?: number; // boundary between mid and high bands (default 2000)
}
```

### FrequencyBands

```typescript
interface FrequencyBands {
  low: number;  // 0–1, dB-scaled RMS energy below lowCrossoverHz
  mid: number;  // 0–1, dB-scaled RMS energy between crossovers
  high: number; // 0–1, dB-scaled RMS energy above highCrossoverHz
}
```

## Events

### Core Events

| Event | Payload | Description |
|-------|---------|-------------|
| `AudioData` | `{ encoded, position, deltaSize, totalSize, soundLevel, frequencyBands?, ... }` | Emitted during mic capture at the configured interval. Includes `frequencyBands` when `frequencyBandConfig` is set. |
| `SoundChunkPlayed` | `{ isFinal: boolean }` | A queued chunk finished playing. `isFinal` when the queue is empty. |
| `SoundStarted` | (none) | Playback began for a new turn. |
| `DeviceReconnected` | `{ reason }` | Audio route changed (headphones, Bluetooth, etc). |

### Pipeline Events

| Event | Payload | Description |
|-------|---------|-------------|
| `PipelineStateChanged` | `{ state }` | Pipeline state transition. |
| `PipelinePlaybackStarted` | `{ turnId }` | Priming gate opened, audio is now audible. |
| `PipelineError` | `{ code, message }` | Non-recoverable error. |
| `PipelineZombieDetected` | `{ playbackHead, stalledMs }` | Audio track stalled. |
| `PipelineUnderrun` | `{ count }` | Jitter buffer underrun (silence inserted). |
| `PipelineDrained` | `{ turnId }` | All buffered audio for the turn has been played. |
| `PipelineFrequencyBands` | `{ low, mid, high }` | Frequency band energy (0–1) emitted at `frequencyBandIntervalMs`. |
| `PipelineAudioFocusLost` | (empty) | Another app took audio focus. |
| `PipelineAudioFocusResumed` | (empty) | Audio focus regained. |

## Constants

```typescript
import {
  EncodingTypes,           // { PCM_F32LE: "pcm_f32le", PCM_S16LE: "pcm_s16le" }
  PlaybackModes,           // { REGULAR, VOICE_PROCESSING, CONVERSATION }
  AudioEvents,             // { AudioData, SoundChunkPlayed, SoundStarted, DeviceReconnected }
  SuspendSoundEventTurnId, // "suspend-sound-events" -- suppresses playback events
} from "@1worldcapture/expo-audio-stream";
```

## Platform Notes

### iOS

- Uses `AVAudioEngine` with `AVAudioPlayerNode` for sound playback and pipeline audio.
- Microphone capture via `AVAudioEngine.inputNode` tap.
- Audio session configured as `.playAndRecord` with `.voiceChat` mode.
- Voice processing (AEC/noise reduction) available via `voiceProcessing` and `conversation` playback modes.
- `promptMicrophoneModes()` exposes the iOS 15+ system voice isolation picker.

### Android

- Uses `AudioTrack` (float PCM, `MODE_STREAM`) for sound playback.
- Microphone capture via `AudioRecord` with `VOICE_RECOGNITION` source for far-field mic gain.
- AEC, noise suppression, and AGC applied via `AudioEffectsManager`.

## License

MIT

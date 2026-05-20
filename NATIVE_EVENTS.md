# Native-to-JS Events Reference

Complete catalog of events emitted from native code (Android/iOS) to JavaScript,
including payload shapes, trigger conditions, and recommended JS responses.

---

## Recording Events

### `AudioData`

Emitted at the configured interval during microphone recording. Also doubles as
the recording error channel.

| Field | Type | Notes |
|---|---|---|
| `encoded` | `string` | Base64-encoded PCM audio |
| `deltaSize` | `number` | Bytes in this chunk |
| `position` | `number` | Position in ms from start of recording |
| `totalSize` | `number` | Cumulative bytes recorded |
| `soundLevel` | `number?` | Power level in dB (-160 when silent) |
| `streamUuid` | `string` | Unique ID for this recording stream |
| `fileUri` | `string` | Always `""` (file I/O removed) |
| `lastEmittedSize` | `number` | Previous `totalSize` value |
| `mimeType` | `string` | e.g. `"audio/wav"` |
| `frequencyBands` | `{ low, mid, high }?` | dB-scaled RMS energy per band (0–1). Present only when `frequencyBandConfig` is passed to `startMicrophone`. |

**Error variant** (same event name, different shape):

| Field | Type | Notes |
|---|---|---|
| `error` | `string` | Error code: `READ_ERROR`, `RECORDING_CRASH` |
| `errorMessage` | `string` | Human-readable description |
| `streamUuid` | `string` | Stream that errored |

**Platform:** Android, iOS

**JS response:**
- Forward the base64 PCM to your STT pipeline or WebSocket.
- Use `soundLevel` for VAD or UI visualisation.
- Check for the `error` field before assuming the payload is audio data.
  On error, stop the conversation turn or retry.

---

### `DeviceReconnected`

Fired when an audio device is connected or disconnected (Bluetooth SCO/A2DP,
wired headset/headphones, USB headset).

| Field | Type | Notes |
|---|---|---|
| `reason` | `string` | `"newDeviceAvailable"` \| `"oldDeviceUnavailable"` \| `"unknown"` |

**Platform:** Android, iOS

**JS response:**
- `oldDeviceUnavailable`: headset/BT just disconnected. Decide whether to stop
  recording, switch to speaker, or show a UI prompt.
- `newDeviceAvailable`: a device was plugged in. May want to re-route audio or
  update UI to reflect the new output device.

---

## Legacy Playback Events (AudioPlaybackManager)

### `SoundStarted`

Fired once per turn when the first audio chunk begins playback.

| Field | Type | Notes |
|---|---|---|
| *(empty payload)* | | |

**Platform:** Android, iOS

**JS response:**
- Show a "speaking" indicator in the UI.
- If half-duplex, mute the microphone.

---

### `SoundChunkPlayed`

Fired after each audio chunk finishes playback.

| Field | Type | Notes |
|---|---|---|
| `isFinal` | `boolean` | `true` if this was the last chunk in the sequence |

**Platform:** Android, iOS

**JS response:**
- `isFinal === false`: progress notification. Use for UI or ignore.
- `isFinal === true`: the turn is done playing. Resume mic recording, send next
  turn, update UI to "listening".

---

## Pipeline Events

These events are emitted by `AudioPipeline` via `PipelineIntegration` on both
Android and iOS.

### `PipelineStateChanged`

Fired on every pipeline state transition.

| Field | Type | Notes |
|---|---|---|
| `state` | `string` | `"idle"` \| `"connecting"` \| `"streaming"` \| `"draining"` \| `"error"` |

**JS response:**
- Drive your UI state machine. `streaming` = show playback indicator.
  `idle` = ready for next turn. `error` = surface to user or trigger reconnect.

---

### `PipelinePlaybackStarted`

Fired once per turn when the jitter buffer has primed and real audio is hitting
the speaker.

| Field | Type | Notes |
|---|---|---|
| `turnId` | `string` | Conversation turn identifier |

**JS response:**
- This is the "time-to-first-audio" measurement point.
- Update UI to "speaking".

---

### `PipelineError`

Fired on any pipeline error condition.

| Field | Type | Notes |
|---|---|---|
| `code` | `string` | See table below |
| `message` | `string` | Human-readable description |

| Code | Meaning | Recommended action |
|---|---|---|
| `CONNECT_FAILED` | AudioTrack or JitterBuffer creation failed | Retry `pipelineConnect()` |
| `DECODE_ERROR` | Base64 decode failed on incoming chunk | Bad data from server -- log and drop the chunk |
| `WRITE_ERROR` | `AudioTrack.write()` returned an error code | `pipelineDisconnect()` then `pipelineConnect()` |
| `NOT_CONNECTED` | `pushAudio` called before `connect` | Ensure connection is established before pushing |

---

### `PipelineZombieDetected`

Fired when the AudioTrack's `playbackHeadPosition` has not moved for 5+ seconds
during `streaming` or `draining` state.

| Field | Type | Notes |
|---|---|---|
| `playbackHead` | `number` | Last known playback head position |
| `stalledMs` | `number` | Milliseconds since head last moved |

**JS response:**
- The AudioTrack is stuck. Tear down and reconnect:
  `pipelineDisconnect()` then `pipelineConnect()`.
- This is a device-level issue (some OEMs, Bluetooth routing glitches).

---

### `PipelineUnderrun`

Fired when the jitter buffer runs dry during playback. Debounced: only fires
when the cumulative count increases, not on every silence frame.

| Field | Type | Notes |
|---|---|---|
| `count` | `number` | Total underrun count for this turn |

**JS response:**
- A single underrun during initial priming is normal.
- Repeated underruns during `streaming` mean the server or JS bridge is not
  delivering audio fast enough. Log for diagnostics. If `count` climbs quickly,
  consider increasing `targetBufferMs`.
- No immediate corrective action is typically needed.

---

### `PipelineDrained`

Fired when the pipeline has played all buffered audio after `markEndOfStream`.
The pipeline transitions from `draining` to `idle`.

| Field | Type | Notes |
|---|---|---|
| `turnId` | `string` | The turn that just finished playing |

**JS response:**
- This is your "turn complete" signal. Resume mic recording, send next request,
  update UI to "listening".
- Equivalent to `SoundChunkPlayed` with `isFinal=true` but for the pipeline path.

---

### `PipelinePlaybackStopped`

Fired approximately `outputLatencyMs` after `PipelineDrained` for the same turn —
i.e., when the last sample physically leaves the speaker. Pairs symmetrically
with `PipelinePlaybackStarted` (start-of-emission ↔ end-of-emission).

**Distinct from `state: 'idle'`:** that's the pipeline-state-machine value
reported via `PipelineStateChanged`. `PipelinePlaybackStopped` is a
physical-world milestone about audible audio, not a state-machine transition.

| Field | Type | Notes |
|---|---|---|
| `turnId` | `string` | The turn whose last sample just stopped emitting |

**Cancellation:** the scheduled dispatch is cancelled if a new turn starts,
`invalidatePipelineTurn` is called, or the pipeline disconnects before the
delay elapses. Consumers will not receive a late-arriving event mid-stream.

**Approximation:** the delay uses `outputLatencyMs` captured at drain time.
On iOS the value reflects `AVAudioSession.outputLatency` (total HW output
latency). On Android it uses `AudioTrack.getTimestamp()` to compute frames
in-flight, falling back to a HAL-buffer estimate if the timestamp call fails.
A route change during the latency window (e.g. switch to Bluetooth mid-tail)
is *not* re-measured — the captured value is used. The error is typically
single-digit milliseconds and is acceptable for VAD-gating use cases.

**Platform:** Android, iOS

**JS response:**
- Use this — not `PipelineDrained` — when you need to know when **mic-side
  echo from the speaker is over**. Useful for voice-agent pipelines that
  gate server-side VAD on the agent's own playback ending.
- If you do not care about the physical-world emission boundary, prefer
  `PipelineDrained` (cheaper, fires earlier).

---

### `PipelineFrequencyBands`

Fired at the interval configured by `frequencyBandIntervalMs` during pipeline
playback. Uses IIR-based frequency splitting and dB-scaled RMS energy.

| Field | Type | Notes |
|---|---|---|
| `low` | `number` | 0–1, energy below `lowCrossoverHz` (default 300 Hz) |
| `mid` | `number` | 0–1, energy between crossover frequencies |
| `high` | `number` | 0–1, energy above `highCrossoverHz` (default 2000 Hz) |

**Platform:** Android, iOS

**JS response:**
- Drive a visual audio meter or waveform visualization.
- Values are dB-scaled from raw RMS so they map well to UI bar heights.
- When no new audio has been pushed, the last known band values are re-emitted
  to maintain a steady cadence. Values drop to zero only when the pipeline is
  idle (disconnected or between turns).

---

### `PipelineAudioFocusLost`

Fired when another app takes audio focus (phone call, navigation, music).
The pipeline continues writing silence to keep the AudioTrack alive.

| Field | Type | Notes |
|---|---|---|
| *(empty payload)* | | |

**JS response:**
- Decide whether to pause the conversation, mute the mic via `toggleSilence(isSilent)`,
  or show a "paused" UI.
- The pipeline will resume playing real audio automatically when focus returns.

---

### `PipelineAudioFocusResumed`

Fired when audio focus is regained (`AUDIOFOCUS_GAIN`).

| Field | Type | Notes |
|---|---|---|
| *(empty payload)* | | |

**JS response:**
- If you paused the conversation or muted the mic on focus loss, undo that now.
- Audio that arrived during the focus-loss window was still buffered in the
  jitter buffer (up to its capacity) and will play out normally.

---

## System Event Handling Gaps

The following system events are **not currently handled** by native code. JS
cannot respond to them because no event is emitted.

| Gap | Impact | Notes |
|---|---|---|
| Phone call interruptions | No `TelephonyManager` / `READ_PHONE_STATE` listener on Android. Partially covered by audio focus loss on the pipeline side; recording side is unprotected. | On iOS, phone calls trigger `interruptionNotification`, but the `.began` handler is a no-op. |
| App lifecycle (background/foreground) | No `OnPause`/`OnResume`/`OnStop` handling on Android. No `willResignActive`/`didBecomeActive` on iOS. | Recording continues in background until the system kills it. No foreground service. |
| `ACTION_AUDIO_BECOMING_NOISY` | Headphones unplugged mid-playback could route audio to the speaker unexpectedly. | Android only. Not registered. |
| Runtime permission revocation | If mic permission is revoked while recording, `AudioRecord.read()` returns errors. Detected by consecutive error counting but no proactive event. | Both platforms. |
| Media button events | No `MediaSession` or remote command center integration. | Both platforms. |
| Do Not Disturb | No detection or adaptation. | Both platforms. Low priority. |

---

## TypeScript Types

All event payload types are defined in `src/events.ts` and
`src/pipeline/types.ts`. Pipeline events can be subscribed to via:

```typescript
import { Pipeline } from "expo-audio-stream";

Pipeline.subscribe("PipelineDrained", (event) => {
  console.log("Turn complete:", event.turnId);
});
```

Recording and legacy playback events use the helpers in `src/events.ts`:

```typescript
import { addAudioEventListener, addSoundChunkPlayedListener } from "expo-audio-stream";

addAudioEventListener(async (event) => { /* ... */ });
addSoundChunkPlayedListener(async (event) => { /* ... */ });
```

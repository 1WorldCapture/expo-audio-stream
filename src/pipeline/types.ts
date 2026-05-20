// ────────────────────────────────────────────────────────────────────────────
// Native Audio Pipeline — V3 TypeScript Types
// ────────────────────────────────────────────────────────────────────────────

import { PlaybackMode, FrequencyBandConfig, FrequencyBands } from "../types";

// ── Connect ─────────────────────────────────────────────────────────────────

/**
 * How the pipeline's playback should coexist with other audio on the device.
 *
 * - `'mixWithOthers'` (default): plays alongside other apps without
 *   interrupting them. On Android no audio focus is requested. Best for
 *   sound effects and short clips.
 * - `'duckOthers'`: requests audio focus with ducking. Other apps lower
 *   their volume but keep playing.
 * - `'doNotMix'`: requests exclusive audio focus. Other apps pause.
 */
export type PipelineAudioMode = 'mixWithOthers' | 'duckOthers' | 'doNotMix';

/** Options passed to `connectPipeline()`. */
export interface ConnectPipelineOptions {
  /** Sample rate in Hz (default 24000). */
  sampleRate?: number;
  /** Number of channels — 1 = mono, 2 = stereo (default 1). */
  channelCount?: number;
  /**
   * How many ms of audio to accumulate in the jitter buffer before the
   * priming gate opens and audio begins playing (default 80).
   */
  targetBufferMs?: number;
  /**
   * Playback mode hint for native optimizations. Affects thread priority and
   */
  playbackMode?: PlaybackMode;
  /** Interval in ms for PipelineFrequencyBands events (default 100). */
  frequencyBandIntervalMs?: number;
  /** Optional frequency band crossover configuration. */
  frequencyBandConfig?: FrequencyBandConfig;
  /**
   * How pipeline playback should coexist with other apps' audio.
   * Default is `'mixWithOthers'` (matches expo-audio).
   *
   * Note: this is a **behavior change** vs. prior versions of this library,
   * which effectively used `'doNotMix'`. Pass `'doNotMix'` explicitly to
   * preserve that old behavior.
   */
  audioMode?: PipelineAudioMode;
}

/** Result returned from a successful `connectPipeline()` call. */
export interface ConnectPipelineResult {
  sampleRate: number;
  channelCount: number;
  targetBufferMs: number;
  /**
   * Frame size in samples derived from the device HAL's
   * `AudioTrack.getMinBufferSize()`. Useful for understanding the write
   * granularity on the native side.
   */
  frameSizeSamples: number;
}

// ── Push Audio ──────────────────────────────────────────────────────────────

/** Options passed to `pushPipelineAudio()` / `pushPipelineAudioSync()`. */
export interface PushPipelineAudioOptions {
  /** Base64-encoded PCM 16-bit signed LE audio data. */
  audio: string;
  /** Conversation turn identifier. */
  turnId: string;
  /** True if this is the first chunk of a new turn (resets jitter buffer). */
  isFirstChunk?: boolean;
  /** True if this is the final chunk of the current turn (marks end-of-stream). */
  isLastChunk?: boolean;
}

// ── Invalidate Turn ─────────────────────────────────────────────────────────

/** Options passed to `invalidatePipelineTurn()`. */
export interface InvalidatePipelineTurnOptions {
  /** The new turn identifier — stale audio for the old turn is discarded. */
  turnId: string;
}

// ── State ───────────────────────────────────────────────────────────────────

/**
 * Pipeline states reported via `PipelineStateChanged` events.
 *
 * - `idle`       — connected but no audio flowing
 * - `connecting` — AudioTrack being created, focus being requested
 * - `streaming`  — actively receiving and playing audio
 * - `draining`   — end-of-stream marked, playing remaining buffer
 * - `error`      — unrecoverable error (zombie, write failure, etc.)
 */
export type PipelineState =
  | 'idle'
  | 'connecting'
  | 'streaming'
  | 'draining'
  | 'error';

// ── Events ──────────────────────────────────────────────────────────────────

/** Payload for `PipelineStateChanged`. */
export interface PipelineStateChangedEvent {
  state: PipelineState;
}

/** Payload for `PipelinePlaybackStarted`. */
export interface PipelinePlaybackStartedEvent {
  turnId: string;
}

/** Payload for `PipelineError`. */
export interface PipelineErrorEvent {
  code: string;
  message: string;
}

/** Payload for `PipelineZombieDetected`. */
export interface PipelineZombieDetectedEvent {
  playbackHead: number;
  stalledMs: number;
}

/** Payload for `PipelineUnderrun`. */
export interface PipelineUnderrunEvent {
  count: number;
}

/** Payload for `PipelineDrained`. */
export interface PipelineDrainedEvent {
  turnId: string;
}

/**
 * Payload for `PipelinePlaybackStopped`.
 *
 * Fired when the last sample physically leaves the speaker, approximately
 * `outputLatencyMs` after `PipelineDrained` for the same turn. Pairs with
 * `PipelinePlaybackStarted` (start-of-emission ↔ end-of-emission).
 *
 * Note: this is a physical-world milestone, distinct from `state: 'idle'`
 * (the pipeline-state-machine value reported via `PipelineStateChanged`).
 */
export interface PipelinePlaybackStoppedEvent {
  turnId: string;
}

/** Payload for `PipelineAudioFocusLost` (empty — presence is the signal). */
export type PipelineAudioFocusLostEvent = Record<string, never>;

/** Payload for `PipelineAudioFocusResumed` (empty — presence is the signal). */
export type PipelineAudioFocusResumedEvent = Record<string, never>;

/** Payload for `PipelineFrequencyBands`. */
export interface PipelineFrequencyBandsEvent extends FrequencyBands {}

/**
 * Map of all pipeline event names to their payload types.
 * Used with `Pipeline.subscribe<K>()` for type-safe event subscriptions.
 */
export interface PipelineEventMap {
  PipelineStateChanged: PipelineStateChangedEvent;
  PipelinePlaybackStarted: PipelinePlaybackStartedEvent;
  PipelineError: PipelineErrorEvent;
  PipelineZombieDetected: PipelineZombieDetectedEvent;
  PipelineUnderrun: PipelineUnderrunEvent;
  PipelineDrained: PipelineDrainedEvent;
  PipelinePlaybackStopped: PipelinePlaybackStoppedEvent;
  PipelineAudioFocusLost: PipelineAudioFocusLostEvent;
  PipelineAudioFocusResumed: PipelineAudioFocusResumedEvent;
  PipelineFrequencyBands: PipelineFrequencyBandsEvent;
}

/** Union of all pipeline event name strings. */
export type PipelineEventName = keyof PipelineEventMap;

// ── Telemetry ───────────────────────────────────────────────────────────────

/** Jitter buffer telemetry counters. */
export interface PipelineBufferTelemetry {
  /** Current buffer level in milliseconds. */
  bufferMs: number;
  /** Current buffer level in samples. */
  bufferSamples: number;
  /** Whether the priming gate has opened. */
  primed: boolean;
  /** Total samples written by the producer since last reset. */
  totalWritten: number;
  /** Total samples read by the consumer since last reset. */
  totalRead: number;
  /** Number of underrun events. */
  underrunCount: number;
  /** Peak buffer level in samples. */
  peakLevel: number;
}

/** Full pipeline telemetry snapshot. */
export interface PipelineTelemetry extends PipelineBufferTelemetry {
  /** Current pipeline state. */
  state: PipelineState;
  /** Total pushAudio/pushAudioSync calls since connect. */
  totalPushCalls: number;
  /** Total bytes pushed since connect. */
  totalPushBytes: number;
  /** Total write-loop iterations since connect. */
  totalWriteLoops: number;
  /** Current turn identifier. */
  turnId: string;
}

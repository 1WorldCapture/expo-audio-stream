// ────────────────────────────────────────────────────────────────────────────
// Native Audio Pipeline — V3 TypeScript Wrapper
// ────────────────────────────────────────────────────────────────────────────
//
// Thin wrapper over the existing ExpoPlayAudioStreamModule (not a new native
// module). Uses static methods matching the existing codebase pattern.
//
// Hot path:  pushAudioSync() — synchronous Function call, no Promise overhead.
// Cold path: pushAudio()     — async with error propagation via Promise.

import type { EventSubscription } from 'expo-modules-core';
import ExpoPlayAudioStreamModule from '../ExpoPlayAudioStreamModule';
import { subscribeToEvent } from '../events';

import type {
  ConnectPipelineOptions,
  ConnectPipelineResult,
  PushPipelineAudioOptions,
  InvalidatePipelineTurnOptions,
  PipelineState,
  PipelineEventMap,
  PipelineEventName,
  PipelineTelemetry,
} from './types';

export class Pipeline {
  // ════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ════════════════════════════════════════════════════════════════════════

  /**
   * Connect the native audio pipeline.
   *
   * Creates an AudioTrack (buffer size from device HAL), jitter buffer, and
   * MAX_PRIORITY write thread. Config is immutable per session — disconnect
   * and reconnect to change sample rate.
   */
  static async connect(
    options: ConnectPipelineOptions = {}
  ): Promise<ConnectPipelineResult> {
    return await ExpoPlayAudioStreamModule.connectPipeline(options);
  }

  /**
   * Disconnect the pipeline. Tears down AudioTrack, write thread, audio
   * focus, volume guard, and zombie detection.
   */
  static async disconnect(): Promise<void> {
    return await ExpoPlayAudioStreamModule.disconnectPipeline();
  }

  // ════════════════════════════════════════════════════════════════════════
  // Push audio
  // ════════════════════════════════════════════════════════════════════════

  /**
   * Push base64-encoded PCM16 audio into the jitter buffer (async).
   *
   * Use this when you need error propagation via Promise rejection.
   * For the hot path (e.g., inside a WebSocket message handler), prefer
   * [pushAudioSync] which avoids Promise overhead.
   */
  static async pushAudio(options: PushPipelineAudioOptions): Promise<void> {
    return await ExpoPlayAudioStreamModule.pushPipelineAudio(options);
  }

  /**
   * Push base64-encoded PCM16 audio synchronously (no Promise overhead).
   *
   * Designed for the hot path — call this from your WebSocket onmessage
   * handler for minimum latency. Returns `true` on success, `false` on
   * failure (errors are also reported via PipelineError events).
   */
  static pushAudioSync(options: PushPipelineAudioOptions): boolean {
    return ExpoPlayAudioStreamModule.pushPipelineAudioSync(options);
  }

  // ════════════════════════════════════════════════════════════════════════
  // Turn management
  // ════════════════════════════════════════════════════════════════════════

  /**
   * Invalidate the current turn. Resets the jitter buffer so stale audio
   * from the old turn is discarded immediately.
   */
  static async invalidateTurn(
    options: InvalidatePipelineTurnOptions
  ): Promise<void> {
    return await ExpoPlayAudioStreamModule.invalidatePipelineTurn(options);
  }

  // ════════════════════════════════════════════════════════════════════════
  // State & Telemetry
  // ════════════════════════════════════════════════════════════════════════

  /** Get the current pipeline state synchronously. */
  static getState(): PipelineState {
    return ExpoPlayAudioStreamModule.getPipelineState() as PipelineState;
  }

  /** Get a telemetry snapshot (buffer levels, counters, etc.). */
  static getTelemetry(): PipelineTelemetry {
    return ExpoPlayAudioStreamModule.getPipelineTelemetry() as PipelineTelemetry;
  }

  /**
   * Query the platform's current output latency — i.e., how long after a
   * sample is written to the native buffer before it actually leaves the
   * speaker.
   *
   * Value can change mid-session, notably on audio route changes such as
   * switching from built-in speaker to Bluetooth (Bluetooth typically adds
   * 100+ ms). **Always query at the moment you care; do not cache.**
   *
   * Returns 0 if the pipeline is not connected or the platform cannot
   * report a value.
   */
  static getOutputLatencyMs(): number {
    return ExpoPlayAudioStreamModule.getPipelineOutputLatencyMs() as number;
  }

  // ════════════════════════════════════════════════════════════════════════
  // Event subscriptions
  // ════════════════════════════════════════════════════════════════════════

  /**
   * Subscribe to a specific pipeline event with full type safety.
   *
   * @example
   * ```ts
   * const sub = Pipeline.subscribe('PipelineStateChanged', async (e) => {
   *   console.log('State:', e.state);
   * });
   * // Later:
   * sub.remove();
   * ```
   */
  static subscribe<K extends PipelineEventName>(
    eventName: K,
    listener: (event: PipelineEventMap[K]) => Promise<void> | void
  ): EventSubscription {
    return subscribeToEvent<PipelineEventMap[K]>(
      eventName,
      async (event) => {
        if (event !== undefined) {
          await listener(event);
        }
      }
    );
  }

  /**
   * Convenience: subscribe to both PipelineError and PipelineZombieDetected.
   *
   * Useful for a single error handler that covers fatal and near-fatal
   * conditions. The callback receives a normalized `{ code, message }`.
   */
  static onError(
    listener: (error: { code: string; message: string }) => void
  ): { remove: () => void } {
    const subs: EventSubscription[] = [];

    subs.push(
      Pipeline.subscribe('PipelineError', async (e) => {
        listener({ code: e.code, message: e.message });
      })
    );

    subs.push(
      Pipeline.subscribe('PipelineZombieDetected', async (e) => {
        listener({
          code: 'ZOMBIE_DETECTED',
          message: `AudioTrack stalled for ${e.stalledMs}ms at head=${e.playbackHead}`,
        });
      })
    );

    return {
      remove: () => subs.forEach((s) => s.remove()),
    };
  }

  /**
   * Convenience: subscribe to audio focus loss and resumption events.
   *
   * During focus loss the pipeline writes silence instead of real audio.
   * The caller should typically invalidateTurn + re-request audio from the
   * AI backend on focus regain.
   */
  static onAudioFocus(
    listener: (event: { focused: boolean }) => void
  ): { remove: () => void } {
    const subs: EventSubscription[] = [];

    subs.push(
      Pipeline.subscribe('PipelineAudioFocusLost', async () => {
        listener({ focused: false });
      })
    );

    subs.push(
      Pipeline.subscribe('PipelineAudioFocusResumed', async () => {
        listener({ focused: true });
      })
    );

    return {
      remove: () => subs.forEach((s) => s.remove()),
    };
  }
}

// Re-export all types for consumer convenience
export type {
  ConnectPipelineOptions,
  ConnectPipelineResult,
  PushPipelineAudioOptions,
  InvalidatePipelineTurnOptions,
  PipelineState,
  PipelineEventMap,
  PipelineEventName,
  PipelineBufferTelemetry,
  PipelineTelemetry,
  PipelineStateChangedEvent,
  PipelinePlaybackStartedEvent,
  PipelineErrorEvent,
  PipelineZombieDetectedEvent,
  PipelineUnderrunEvent,
  PipelineDrainedEvent,
  PipelinePlaybackStoppedEvent,
  PipelineAudioFocusLostEvent,
  PipelineAudioFocusResumedEvent,
} from './types';

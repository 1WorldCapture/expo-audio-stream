import type { EventSubscription } from "expo-modules-core";
import ExpoPlayAudioStreamModule from "./ExpoPlayAudioStreamModule";

// Type alias for backwards compatibility
type Subscription = EventSubscription;
import {
  AudioDataEvent,
  AudioRecording,
  RecordingConfig,
  StartRecordingResult,
  PlaybackMode,
  Encoding,
  EncodingTypes,
  FrequencyBands,
  PlaybackModes,
  // Audio jitter buffer types
  IAudioBufferConfig,
  IAudioPlayPayload,
  IAudioFrame,
  BufferHealthState,
  IBufferHealthMetrics,
  IAudioBufferManager,
  IFrameProcessor,
  IQualityMonitor,
  BufferedStreamConfig,
  SmartBufferConfig,
  SmartBufferMode,
  NetworkConditions,
} from "./types";

import {
  addAudioEventListener,
  AudioEventPayload,
  AudioEvents,
  subscribeToEvent,
  DeviceReconnectedReason,
  DeviceReconnectedEventPayload,
} from "./events";

export class ExpoPlayAudioStream {
  /**
   * Destroys the audio stream module, cleaning up all resources.
   * This should be called when the module is no longer needed.
   * It will reset all internal state and release audio resources.
   */
  static async destroy() {
    await ExpoPlayAudioStreamModule.destroy();
  }

  /**
   * Starts microphone streaming.
   * @param {RecordingConfig} recordingConfig - The recording configuration.
   * @returns {Promise<{recordingResult: StartRecordingResult, subscription: Subscription}>} A promise that resolves to an object containing the recording result and a subscription to audio events.
   * @throws {Error} If the recording fails to start.
   */
  static async startMicrophone(recordingConfig: RecordingConfig): Promise<{
    recordingResult: StartRecordingResult;
    subscription?: Subscription;
  }> {
    let subscription: Subscription | undefined;
    try {
      const { onAudioStream, onError, ...options } = recordingConfig;

      if (
        (onAudioStream && typeof onAudioStream == "function") ||
        (onError && typeof onError == "function")
      ) {
        subscription = addAudioEventListener(
          async (event: AudioEventPayload) => {
            const {
              fileUri,
              deltaSize,
              totalSize,
              position,
              encoded,
              soundLevel,
              frequencyBands,
              error,
              errorMessage,
            } = event;
            if (error) {
              onError?.({ code: error, message: errorMessage ?? "" });
              return;
            }
            if (!encoded) {
              console.error(
                `[ExpoPlayAudioStream] Encoded audio data is missing`
              );
              throw new Error("Encoded audio data is missing");
            }
            onAudioStream?.({
              data: encoded,
              position,
              fileUri,
              eventDataSize: deltaSize,
              totalSize,
              soundLevel,
              frequencyBands,
            });
          }
        );
      }

      const result = await ExpoPlayAudioStreamModule.startMicrophone(options);

      return { recordingResult: result, subscription };
    } catch (error) {
      console.error(error);
      subscription?.remove();
      throw new Error(`Failed to start recording: ${error}`);
    }
  }

  /**
   * Stops the current microphone streaming.
   * @returns {Promise<void>}
   * @throws {Error} If the microphone streaming fails to stop.
   */
  static async stopMicrophone(): Promise<AudioRecording | null> {
    try {
      return await ExpoPlayAudioStreamModule.stopMicrophone();
    } catch (error) {
      console.error(error);
      throw new Error(`Failed to stop mic stream: ${error}`);
    }
  }

  /**
   * Subscribes to audio events emitted during recording/streaming.
   * @param onMicrophoneStream - Callback function that will be called when audio data is received.
   * @returns {Subscription} A subscription object that can be used to unsubscribe from the events
   */
  static subscribeToAudioEvents(
    onMicrophoneStream: (event: AudioDataEvent) => Promise<void>
  ): Subscription {
    return addAudioEventListener(async (event: AudioEventPayload) => {
      const { fileUri, deltaSize, totalSize, position, encoded, soundLevel, frequencyBands } =
        event;
      if (!encoded) {
        console.error(`[ExpoPlayAudioStream] Encoded audio data is missing`);
        throw new Error("Encoded audio data is missing");
      }
      onMicrophoneStream?.({
        data: encoded,
        position,
        fileUri,
        eventDataSize: deltaSize,
        totalSize,
        soundLevel,
        frequencyBands,
      });
    });
  }

  /**
   * Subscribes to events emitted by the audio stream module, for advanced use cases.
   * @param eventName - The name of the event to subscribe to.
   * @param onEvent - Callback function that will be called when the event is emitted.
   * @returns {Subscription} A subscription object that can be used to unsubscribe from the events.
   */
  static subscribe<T extends unknown>(
    eventName: string,
    onEvent: (event: T | undefined) => Promise<void>
  ): Subscription {
    return subscribeToEvent(eventName, onEvent);
  }

  /**
   * Prompts the user to select the microphone mode.
   * @returns {Promise<void>}
   * @throws {Error} If the microphone mode fails to prompt.
   */
  static promptMicrophoneModes() {
    ExpoPlayAudioStreamModule.promptMicrophoneModes();
  }

  /**
   * Toggles the silence state of the microphone.
   * @returns {Promise<void>}
   * @throws {Error} If the microphone fails to toggle silence.
   */
  static toggleSilence(isSilent: boolean) {
    ExpoPlayAudioStreamModule.toggleSilence(isSilent);
  }

  /**
   * Requests microphone permission from the user.
   * @returns {Promise<{granted: boolean, canAskAgain?: boolean, status?: string}>} A promise that resolves to the permission result.
   */
  static async requestPermissionsAsync(): Promise<{
    granted: boolean;
    canAskAgain?: boolean;
    status?: string;
  }> {
    try {
      return await ExpoPlayAudioStreamModule.requestPermissionsAsync();
    } catch (error) {
      console.error(error);
      throw new Error(`Failed to request permissions: ${error}`);
    }
  }

  /**
   * Gets the current microphone permission status.
   * @returns {Promise<{granted: boolean, canAskAgain?: boolean, status?: string}>} A promise that resolves to the permission status.
   */
  static async getPermissionsAsync(): Promise<{
    granted: boolean;
    canAskAgain?: boolean;
    status?: string;
  }> {
    try {
      return await ExpoPlayAudioStreamModule.getPermissionsAsync();
    } catch (error) {
      console.error(error);
      throw new Error(`Failed to get permissions: ${error}`);
    }
  }
}

export {
  AudioDataEvent,
  DeviceReconnectedReason,
  DeviceReconnectedEventPayload,
  AudioRecording,
  RecordingConfig,
  StartRecordingResult,
  AudioEvents,
  PlaybackMode,
  Encoding,
  EncodingTypes,
  FrequencyBands,
  PlaybackModes,
  // Audio jitter buffer types
  IAudioBufferConfig,
  IAudioPlayPayload,
  IAudioFrame,
  BufferHealthState,
  IBufferHealthMetrics,
  IAudioBufferManager,
  IFrameProcessor,
  IQualityMonitor,
  BufferedStreamConfig,
  SmartBufferConfig,
  SmartBufferMode,
  NetworkConditions,
};

// Re-export Subscription type for backwards compatibility
export type { EventSubscription } from "expo-modules-core";
export type { Subscription } from "./events";

// Export native audio pipeline V3
export { Pipeline } from "./pipeline";
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
} from "./pipeline";

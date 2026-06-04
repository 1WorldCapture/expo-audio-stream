// packages/expo-audio-stream/src/events.ts

import { EventEmitter, type EventSubscription } from "expo-modules-core";

// Type alias for backwards compatibility
export type Subscription = EventSubscription;

import ExpoPlayAudioStreamModule from "./ExpoPlayAudioStreamModule";

const emitter = new EventEmitter(ExpoPlayAudioStreamModule);

export interface AudioEventPayload {
  encoded?: string;
  buffer?: Float32Array;
  fileUri: string;
  lastEmittedSize: number;
  position: number;
  deltaSize: number;
  totalSize: number;
  mimeType: string;
  streamUuid: string;
  soundLevel?: number;
  frequencyBands?: { low: number; mid: number; high: number };
  /** Set by native when a mid-recording error occurs (interruption, read failure).
   * When present, `encoded` is absent and the recording is no longer active. */
  error?: string;
  errorMessage?: string;
}

export const DeviceReconnectedReasons = {
  newDeviceAvailable: "newDeviceAvailable",
  oldDeviceUnavailable: "oldDeviceUnavailable",
  unknown: "unknown",
} as const;

export type DeviceReconnectedReason =
  (typeof DeviceReconnectedReasons)[keyof typeof DeviceReconnectedReasons];

export type DeviceReconnectedEventPayload = {
  reason: DeviceReconnectedReason;
};

export const AudioEvents = {
  AudioData: "AudioData",
  MicrophoneError: "MicrophoneError",
  DeviceReconnected: "DeviceReconnected",
};

export function addAudioEventListener(
  listener: (event: AudioEventPayload) => Promise<void>
): EventSubscription {
  return (emitter as any).addListener("AudioData", listener);
}

export interface MicrophoneErrorEventPayload {
  code: string;
  message: string;
  isFatal: boolean;
  autoResuming: boolean;
}

/**
 * Subscribe to the dedicated MicrophoneError native event.
 *
 * OTA safe: if the running native binary predates this feature, the event is
 * never emitted and this listener is never called. Apps that also subscribe to
 * AudioData errors via addAudioEventListener continue to work unchanged.
 *
 * @example
 * const sub = addMicrophoneErrorListener((e) => {
 *   if (e.isFatal) { stopMicrophone(); reconnect(); }
 *   else if (e.autoResuming) { showPausedUI(); }
 * })
 * // cleanup: sub.remove()
 */
export function addMicrophoneErrorListener(
  listener: (event: MicrophoneErrorEventPayload) => void
): EventSubscription {
  return (emitter as any).addListener("MicrophoneError", listener);
}

export function subscribeToEvent<T extends unknown>(
  eventName: string,
  listener: (event: T | undefined) => Promise<void>
): EventSubscription {
  return (emitter as any).addListener(eventName, listener);
}

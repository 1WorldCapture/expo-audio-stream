import { Button, Platform, ScrollView, StyleSheet, Text, View } from "react-native";
import {
  ExpoPlayAudioStream,
  Pipeline,
} from "@1worldcapture/expo-audio-stream";
import { useEffect, useRef, useState } from "react";
import { sampleA } from "./samples/sample-a";
import type {
  AudioDataEvent,
  FrequencyBands,
} from "@1worldcapture/expo-audio-stream";
import type { EventSubscription } from "expo-modules-core";
import { MicrophoneErrorEvent } from "@1worldcapture/expo-audio-stream/types";

const ANDROID_SAMPLE_RATE = 16000;
const IOS_SAMPLE_RATE = 24000;
const CHANNELS = 1;
const ENCODING = "pcm_16bit";
const RECORDING_INTERVAL = 100;

// Sample audio files are encoded at 16kHz
const SAMPLE_PLAYBACK_RATE = 16000;

const chaosMonkey = () => {
  // At random, frequent intervals, busy wait the JS thread for 100-200ms to see how audio playback and pipeline handle JS thread starvation
  return setInterval(() => {
    const now = Date.now();
    const busyTime = 100 + Math.random() * 100;
    while (Date.now() - now < busyTime) {
      // Busy wait
    }
    console.log(`Chaos monkey busy wait for ${Math.round(busyTime)}ms`);
  }, 500);
}

export default function App() {
  const [pipelineState, setPipelineState] = useState<string>("idle");
  const [pipelineError, setPipelineError] = useState<{
    code: string;
    message: string;
  } | null>(null);
  const [isRecording, setIsRecording] = useState(false);
  const [isSilenced, setIsSilenced] = useState(false);
  const [audioLevel, setAudioLevel] = useState(-180)
  const [micBands, setMicBands] = useState<FrequencyBands | null>(null);
  const [pipelineBands, setPipelineBands] = useState<FrequencyBands | null>(null);
  const [driftMetrics, setDriftMetrics] = useState<{
    clockSec: number;
    pcmSec: number;
    driftSec: number;
    driftPct: number;
  } | null>(null);

  const eventListenerSubscriptionRef = useRef<EventSubscription | undefined>(
    undefined
  );
  const recordingStartRef = useRef<number | null>(null);
  // Drift anchor: stamped from the FIRST audio packet (clock + cumulative bytes)
  // so startup latency (route switch, AEC init, AudioRecord warmup) is excluded
  // and the meter shows only drift *accumulation* under stress.
  const driftAnchorRef = useRef<{ clock: number; bytes: number } | null>(null);
  const recordingSampleRateRef = useRef<number>(24000);

  const pipelineSubsRef = useRef<{ remove: () => void }[]>([]);

  const chaosTimeoutRef = useRef<NodeJS.Timeout | undefined>(undefined);
  const gainRampRef = useRef<NodeJS.Timeout | undefined>(undefined);

  const startChaosMonkey = () => {
    if (!chaosTimeoutRef.current) {
      chaosTimeoutRef.current = chaosMonkey();
    }
  };

  const stopChaosMonkey = () => {
    if (chaosTimeoutRef.current) {
      clearInterval(chaosTimeoutRef.current);
      chaosTimeoutRef.current = undefined;
    }
  };

  const onAudioCallback = async (audio: AudioDataEvent) => {
    if (audio.frequencyBands) {
      setMicBands(audio.frequencyBands);
    }
    setAudioLevel(audio.soundLevel ?? -180);

    if (recordingStartRef.current !== null) {
      const bytesPerSample = 2; // pcm_16bit = 2 bytes
      const byteRate = recordingSampleRateRef.current * CHANNELS * bytesPerSample;
      // Anchor on the first packet so the constant startup offset is removed and
      // only accumulating drift/steps show up.
      if (driftAnchorRef.current === null) {
        driftAnchorRef.current = { clock: Date.now(), bytes: audio.totalSize };
      }
      const anchor = driftAnchorRef.current;
      const clockSec = (Date.now() - anchor.clock) / 1000;
      const pcmSec = (audio.totalSize - anchor.bytes) / byteRate;
      const driftSec = pcmSec - clockSec;
      const driftPct = clockSec > 0 ? (driftSec / clockSec) * 100 : 0;
      setDriftMetrics({ clockSec, pcmSec, driftSec, driftPct });
    }
  };

  const onMicError = async(err: MicrophoneErrorEvent) => {
    console.debug(`Mic error: ${err.code} ${err.message} willResume=${err.autoResuming} fatal=${err.isFatal}`)
    if (err.isFatal || !err.autoResuming) {
      await ExpoPlayAudioStream.stopMicrophone();
      setIsRecording(false)
    }
  };

  useEffect(() => {
    return () => {
      if (gainRampRef.current) clearInterval(gainRampRef.current);
      ExpoPlayAudioStream.destroy().catch();
    };
  }, []);

  const connectPipeline = async () => {
    setPipelineError(null);
    try {
      const result = await Pipeline.connect({
        sampleRate: SAMPLE_PLAYBACK_RATE,
        channelCount: 1,
        targetBufferMs: 80,
        playbackMode: "conversation",
        frequencyBandIntervalMs: 100,
        audioMode: "doNotMix",
      });
      console.log("Pipeline connected:", result);

      // Subscribe to all pipeline events
      const stateSub = Pipeline.subscribe(
        "PipelineStateChanged",
        async (e) => {
          console.log("Pipeline state:", e.state);
          setPipelineState(e.state);
        }
      );

      const playbackStartedSub = Pipeline.subscribe(
        "PipelinePlaybackStarted",
        async (e) => {
          console.log("Pipeline playback started, turnId:", e.turnId);
          // Drop mic to 20% immediately, then ramp linearly back to 100% over 1.5s
          // to give the AEC adaptive filter time to converge before the mic is loud.
          if (gainRampRef.current) clearInterval(gainRampRef.current);
          ExpoPlayAudioStream.setMicrophoneGain(0.2);
          console.debug(`[mic] gain ${0.2}`)
          const RAMP_MS = 1500;
          const TICK_MS = 50;
          const startedAt = Date.now();
          gainRampRef.current = setInterval(() => {
            const elapsed = Date.now() - startedAt;
            if (elapsed >= RAMP_MS) {
              ExpoPlayAudioStream.setMicrophoneGain(1.0);
              console.debug(`[mic] gain ${1}`)
              clearInterval(gainRampRef.current);
              gainRampRef.current = undefined;
              return;
            }
            const nextGain = 0.2 + 0.8 * (elapsed / RAMP_MS)
            console.debug(`[mic] gain ${nextGain}`)
            ExpoPlayAudioStream.setMicrophoneGain(nextGain);
          }, TICK_MS);
        }
      );

      const drainSub = Pipeline.subscribe("PipelineDrained", async (e) => {
        console.log("Pipeline drained, turnId:", e.turnId);
      });

      const underrunSub = Pipeline.subscribe(
        "PipelineUnderrun",
        async (e) => {
          console.log("Pipeline underrun, count:", e.count);
        }
      );

      const errorSub = Pipeline.onError(async (err) => {
        console.error(`Pipeline error: ${err.code} - ${err.message}`);
        if (err.code === "ENGINE_DIED") {
          setPipelineError(err);
          // Auto-disconnect to clean up all state
          try {
            await Pipeline.disconnect();
          } catch (_) {
            // Already torn down on native side, ignore
          }
          pipelineSubsRef.current.forEach((s) => s.remove());
          pipelineSubsRef.current = [];
          setPipelineState("idle");
        }
      });

      const focusSub = Pipeline.onAudioFocus((e) => {
        console.log("Pipeline audio focus:", e.focused ? "resumed" : "lost");
      });

      const freqBandsSub = Pipeline.subscribe(
        "PipelineFrequencyBands",
        (e) => {
          setPipelineBands({ low: e.low, mid: e.mid, high: e.high });
        }
      );

      pipelineSubsRef.current = [
        stateSub,
        playbackStartedSub,
        drainSub,
        underrunSub,
        errorSub,
        focusSub,
        freqBandsSub,
      ];
    } catch (err) {
      console.error("Pipeline connect failed:", err);
    }
  };

  const disconnectPipeline = async () => {
    try {
      if (gainRampRef.current) {
        clearInterval(gainRampRef.current);
        gainRampRef.current = undefined;
        ExpoPlayAudioStream.setMicrophoneGain(1.0);
      }
      await Pipeline.disconnect();
      pipelineSubsRef.current.forEach((s) => s.remove());
      pipelineSubsRef.current = [];
      setPipelineState("idle");
      setPipelineBands(null);
    } catch (err) {
      console.error("Pipeline disconnect failed:", err);
    }
  };

  const pushSampleToPipeline = () => {
    const success = Pipeline.pushAudioSync({
      audio: sampleA,
      turnId: "pipeline-turn-1",
      isFirstChunk: true,
      isLastChunk: true,
    });
    console.log("Pipeline push:", success ? "ok" : "failed");
  };

  const pushSample10x = () => {
    const turnId = "pipeline-turn-10x";
    for (let i = 0; i < 10; i++) {
      const success = Pipeline.pushAudioSync({
        audio: sampleA,
        turnId,
        isFirstChunk: i === 0,
        isLastChunk: i === 9,
      });
      console.log(`Pipeline push ${i + 1}/10:`, success ? "ok" : "failed");
    }
  };

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.header}>expo-audio-stream</Text>

      {/* ── Chaos Monkey ─────────────────────────────────── */}
      <Text style={styles.section}>Chaos</Text>
      <Button onPress={startChaosMonkey} title="Start Chaos Monkey" />
      <Spacer />
      <Button onPress={stopChaosMonkey} title="Stop Chaos Monkey" />
      <Spacer />

      {/* ── Microphone ─────────────────────────────────── */}
      <Text style={styles.section}>Microphone</Text>

      <Button
        onPress={async () => {
          if (!(await isMicrophonePermissionGranted())) {
            const granted = await requestMicrophonePermission();
            if (!granted) return;
          }
          const sampleRate =
            Platform.OS === "ios" ? IOS_SAMPLE_RATE : ANDROID_SAMPLE_RATE;
          const { recordingResult, subscription } =
            await ExpoPlayAudioStream.startMicrophone({
              interval: RECORDING_INTERVAL,
              sampleRate,
              channels: CHANNELS,
              encoding: ENCODING,
              onAudioStream: onAudioCallback,
              onError: onMicError,
              frequencyBandConfig: {
                lowCrossoverHz: 300,
                highCrossoverHz: 2000,
              },
            });
          console.log("Recording started:", JSON.stringify(recordingResult));
          eventListenerSubscriptionRef.current = subscription;
          recordingStartRef.current = Date.now();
          driftAnchorRef.current = null; // re-anchor on first packet of this session
          recordingSampleRateRef.current = sampleRate;
          setDriftMetrics(null);
          setIsRecording(true);
        }}
        title="Start Microphone"
      />
      <Spacer />

      <Button
        onPress={async () => {
          await ExpoPlayAudioStream.stopMicrophone();
          eventListenerSubscriptionRef.current?.remove();
          eventListenerSubscriptionRef.current = undefined;
          recordingStartRef.current = null;
          driftAnchorRef.current = null;
          setIsRecording(false);
          setIsSilenced(false);
          setMicBands(null);
        }}
        title="Stop Microphone"
      />
      <Spacer />

      <Button
        disabled={!isRecording}
        onPress={() => {
          const next = !isSilenced;
          ExpoPlayAudioStream.toggleSilence(next);
          setIsSilenced(next);
        }}
        title={isSilenced ? "Disable Silence" : "Enable Silence"}
      />

      <Text style={styles.status}>
        Mic: {isRecording ? (isSilenced ? "silenced" : "recording") : "idle"}
      </Text>
      {audioLevel && <Text style={styles.status}>
        Mic: {audioLevel}
      </Text>}
      {micBands && <BandMeter label="Mic Bands" bands={micBands} />}
      {driftMetrics && <DriftMeter metrics={driftMetrics} />}

      {/* ── Pipeline ───────────────────────────────────── */}
      <Text style={styles.section}>Pipeline</Text>

      <Button onPress={connectPipeline} title="Connect Pipeline" />
      <Spacer />

      <Button onPress={pushSampleToPipeline} title="Push Sample to Pipeline" />
      <Spacer />

      <Button onPress={pushSample10x} title="Push Sample 10x (buffer test)" />
      <Spacer />

      <Button
        onPress={() => {
          Pipeline.invalidateTurn({ turnId: "pipeline-turn-2" });
          console.log("Turn invalidated");
        }}
        title="Invalidate Turn"
      />
      <Spacer />

      <Button
        onPress={() => {
          const telemetry = Pipeline.getTelemetry();
          console.log("Telemetry:", JSON.stringify(telemetry, null, 2));
        }}
        title="Log Telemetry"
      />
      <Spacer />

      <Button onPress={disconnectPipeline} title="Disconnect Pipeline" />
      <Spacer />

      {/* ── Race condition tests ─────────────────────────── */}
      <Button
        onPress={async () => {
          // Race: disconnect + destroy fired back-to-back (no await between)
          console.log("[Race Test] disconnect + destroy (no await)");
          Pipeline.disconnect().catch((e: unknown) =>
            console.log("[Race Test] disconnect error (expected):", e)
          );
          ExpoPlayAudioStream.destroy().catch((e: unknown) =>
            console.log("[Race Test] destroy error (expected):", e)
          );
        }}
        title="Race: disconnect + destroy"
      />
      <Spacer />
      <Button
        onPress={async () => {
          // Race: rapid connect→disconnect cycle
          console.log("[Race Test] rapid connect/disconnect x5");
          for (let i = 0; i < 5; i++) {
            Pipeline.connect({
              sampleRate: SAMPLE_PLAYBACK_RATE,
              channelCount: 1,
              targetBufferMs: 80,
              playbackMode: "conversation",
            }).catch((e: unknown) =>
              console.log(`[Race Test] connect ${i} error (expected):`, e)
            );
            Pipeline.disconnect().catch((e: unknown) =>
              console.log(`[Race Test] disconnect ${i} error (expected):`, e)
            );
          }
        }}
        title="Race: connect/disconnect x5"
      />
      <Spacer />
      <Button
        onPress={async () => {
          // Race: push audio while disconnecting
          console.log("[Race Test] push + disconnect simultaneous");
          await Pipeline.connect({
            sampleRate: SAMPLE_PLAYBACK_RATE,
            channelCount: 1,
            targetBufferMs: 80,
            playbackMode: "conversation",
          });
          // Fire push and disconnect without awaiting
          for (let i = 0; i < 10; i++) {
            Pipeline.pushAudioSync({
              audio: sampleA,
              turnId: "race-turn",
              isFirstChunk: i === 0,
              isLastChunk: i === 9,
            });
          }
          Pipeline.disconnect().catch((e: unknown) =>
            console.log("[Race Test] disconnect error (expected):", e)
          );
        }}
        title="Race: push + disconnect"
      />

      <Text style={styles.status}>Pipeline: {pipelineState}</Text>
      {pipelineBands && <BandMeter label="Pipeline Bands" bands={pipelineBands} />}

      {pipelineError && (
        <View style={styles.errorBanner}>
          <Text style={styles.errorTitle}>Audio Engine Error</Text>
          <Text style={styles.errorMessage}>
            {pipelineError.code}: {pipelineError.message}
          </Text>
          <Spacer />
          <Button
            onPress={connectPipeline}
            title="Reconnect Pipeline"
            color="#fff"
          />
        </View>
      )}
    </ScrollView>
  );
}

function Spacer() {
  return <View style={{ height: 8 }} />;
}

function BandMeter({ label, bands }: { label: string; bands: FrequencyBands }) {
  const fmt = (v: number) => v.toFixed(4);
  const barWidth = (v: number) => `${Math.min(v * 100, 100)}%` as const;
  return (
    <View style={styles.bandContainer}>
      <Text style={styles.bandLabel}>{label}</Text>
      {(["low", "mid", "high"] as const).map((band) => (
        <View key={band} style={styles.bandRow}>
          <Text style={styles.bandName}>{band}</Text>
          <View style={styles.bandBarBg}>
            <View
              style={[
                styles.bandBarFill,
                {
                  width: barWidth(bands[band]),
                  backgroundColor:
                    band === "low" ? "#4caf50" : band === "mid" ? "#ff9800" : "#f44336",
                },
              ]}
            />
          </View>
          <Text style={styles.bandValue}>{fmt(bands[band])}</Text>
        </View>
      ))}
    </View>
  );
}

function DriftMeter({ metrics }: {
  metrics: { clockSec: number; pcmSec: number; driftSec: number; driftPct: number };
}) {
  const fmt = (s: number) => s.toFixed(2) + "s";
  const sign = (n: number) => (n >= 0 ? "+" : "");
  const driftColor =
    Math.abs(metrics.driftPct) < 2 ? "#4caf50"
    : Math.abs(metrics.driftPct) < 5 ? "#ff9800"
    : "#f44336";
  return (
    <View style={styles.bandContainer}>
      <Text style={styles.bandLabel}>PCM Drift</Text>
      <View style={styles.driftRow}>
        <Text style={styles.driftLabel}>Clock</Text>
        <Text style={styles.driftValue}>{fmt(metrics.clockSec)}</Text>
      </View>
      <View style={styles.driftRow}>
        <Text style={styles.driftLabel}>PCM</Text>
        <Text style={styles.driftValue}>{fmt(metrics.pcmSec)}</Text>
      </View>
      <View style={styles.driftRow}>
        <Text style={styles.driftLabel}>Drift</Text>
        <Text style={[styles.driftValue, { color: driftColor }]}>
          {sign(metrics.driftSec)}{fmt(metrics.driftSec)} ({sign(metrics.driftPct)}{metrics.driftPct.toFixed(1)}%)
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexGrow: 1,
    backgroundColor: "#fff",
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 60,
    paddingHorizontal: 20,
  },
  header: {
    fontSize: 20,
    fontWeight: "bold",
    marginBottom: 20,
  },
  section: {
    fontSize: 16,
    fontWeight: "600",
    marginTop: 24,
    marginBottom: 10,
    alignSelf: "flex-start",
    color: "#333",
  },
  status: {
    marginTop: 8,
    fontSize: 13,
    color: "#666",
  },
  errorBanner: {
    marginTop: 20,
    backgroundColor: "#d32f2f",
    borderRadius: 8,
    padding: 16,
    alignSelf: "stretch",
    alignItems: "center",
  },
  errorTitle: {
    color: "#fff",
    fontWeight: "bold",
    fontSize: 15,
    marginBottom: 4,
  },
  errorMessage: {
    color: "#ffcdd2",
    fontSize: 12,
    textAlign: "center",
  },
  bandContainer: {
    marginTop: 8,
    alignSelf: "stretch",
    padding: 10,
    backgroundColor: "#f5f5f5",
    borderRadius: 8,
  },
  bandLabel: {
    fontSize: 13,
    fontWeight: "600",
    marginBottom: 6,
    color: "#333",
  },
  bandRow: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 4,
  },
  bandName: {
    width: 32,
    fontSize: 12,
    color: "#666",
  },
  bandBarBg: {
    flex: 1,
    height: 10,
    backgroundColor: "#ddd",
    borderRadius: 5,
    marginHorizontal: 6,
    overflow: "hidden",
  },
  bandBarFill: {
    height: "100%",
    borderRadius: 5,
  },
  bandValue: {
    width: 50,
    fontSize: 11,
    color: "#999",
    textAlign: "right",
  },
  driftRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginBottom: 4,
  },
  driftLabel: {
    fontSize: 12,
    color: "#666",
    width: 40,
  },
  driftValue: {
    fontSize: 12,
    color: "#333",
    fontVariant: ["tabular-nums"],
  },
});

const requestMicrophonePermission = async (): Promise<boolean> => {
  const result = await ExpoPlayAudioStream.requestPermissionsAsync();
  return result.granted;
};

const isMicrophonePermissionGranted = async (): Promise<boolean> => {
  const result = await ExpoPlayAudioStream.getPermissionsAsync();
  return result.granted;
};

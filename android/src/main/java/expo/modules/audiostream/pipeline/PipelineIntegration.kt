package expo.modules.audiostream.pipeline

import android.content.Context
import android.os.Bundle
import android.util.Log
import expo.modules.audiostream.EventSender

/**
 * Bridge layer wiring [AudioPipeline] into the existing ExpoPlayAudioStreamModule.
 *
 * This class holds the pipeline instance, implements [PipelineListener] to forward
 * native events as Expo bridge events, and exposes the 7 bridge methods that the
 * module's definition() block should declare.
 *
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │  INTEGRATION STEPS for ExpoPlayAudioStreamModule.kt                    │
 * │                                                                        │
 * │  1. Add field:                                                         │
 * │       private lateinit var pipelineIntegration: PipelineIntegration    │
 * │                                                                        │
 * │  2. Initialize after existing managers (inside definition() block):    │
 * │       initializePipeline()                                             │
 * │     And add the method:                                                │
 * │       private fun initializePipeline() {                               │
 * │           val ctx = appContext.reactContext                             │
 * │               ?: throw IllegalStateException("Context not available")  │
 * │           pipelineIntegration = PipelineIntegration(ctx, this)         │
 * │       }                                                                │
 * │                                                                        │
 * │  3. Add 8 event names to the Events() block:                          │
 * │       PipelineIntegration.EVENT_STATE_CHANGED,                         │
 * │       PipelineIntegration.EVENT_PLAYBACK_STARTED,                      │
 * │       PipelineIntegration.EVENT_ERROR,                                 │
 * │       PipelineIntegration.EVENT_ZOMBIE_DETECTED,                       │
 * │       PipelineIntegration.EVENT_UNDERRUN,                              │
 * │       PipelineIntegration.EVENT_DRAINED,                               │
 * │       PipelineIntegration.EVENT_AUDIO_FOCUS_LOST,                      │
 * │       PipelineIntegration.EVENT_AUDIO_FOCUS_RESUMED                    │
 * │                                                                        │
 * │  4. Add 7 AsyncFunction / Function declarations:                       │
 * │                                                                        │
 * │       AsyncFunction("connectPipeline") { options: Map<String, Any?>,   │
 * │           promise: Promise ->                                          │
 * │           pipelineIntegration.connect(options, promise)                 │
 * │       }                                                                │
 * │                                                                        │
 * │       AsyncFunction("pushPipelineAudio") { options: Map<String, Any?>, │
 * │           promise: Promise ->                                          │
 * │           pipelineIntegration.pushAudio(options, promise)              │
 * │       }                                                                │
 * │                                                                        │
 * │       Function("pushPipelineAudioSync") { options: Map<String, Any?> ->│
 * │           pipelineIntegration.pushAudioSync(options)                    │
 * │       }                                                                │
 * │                                                                        │
 * │       AsyncFunction("disconnectPipeline") { promise: Promise ->        │
 * │           pipelineIntegration.disconnect(promise)                       │
 * │       }                                                                │
 * │                                                                        │
 * │       AsyncFunction("invalidatePipelineTurn") {                        │
 * │           options: Map<String, Any?>, promise: Promise ->              │
 * │           pipelineIntegration.invalidateTurn(options, promise)          │
 * │       }                                                                │
 * │                                                                        │
 * │       Function("getPipelineTelemetry") {                               │
 * │           pipelineIntegration.getTelemetry()                            │
 * │       }                                                                │
 * │                                                                        │
 * │       Function("getPipelineState") {                                   │
 * │           pipelineIntegration.getState()                                │
 * │       }                                                                │
 * │                                                                        │
 * │  5. Call in OnDestroy and destroy():                                   │
 * │       pipelineIntegration.destroy()                                     │
 * │                                                                        │
 * └─────────────────────────────────────────────────────────────────────────┘
 */
class PipelineIntegration(
    private val context: Context,
    private val eventSender: EventSender
) : PipelineListener {

    companion object {
        private const val TAG = "PipelineIntegration"

        // ── Event name constants (match the TS PipelineEventMap keys) ───
        const val EVENT_STATE_CHANGED      = "PipelineStateChanged"
        const val EVENT_PLAYBACK_STARTED   = "PipelinePlaybackStarted"
        const val EVENT_ERROR              = "PipelineError"
        const val EVENT_ZOMBIE_DETECTED    = "PipelineZombieDetected"
        const val EVENT_UNDERRUN           = "PipelineUnderrun"
        const val EVENT_DRAINED            = "PipelineDrained"
        const val EVENT_PLAYBACK_STOPPED   = "PipelinePlaybackStopped"
        const val EVENT_AUDIO_FOCUS_LOST   = "PipelineAudioFocusLost"
        const val EVENT_AUDIO_FOCUS_RESUMED = "PipelineAudioFocusResumed"
        const val EVENT_FREQUENCY_BANDS = "PipelineFrequencyBands"
    }

    private var pipeline: AudioPipeline? = null

    // ════════════════════════════════════════════════════════════════════
    // Bridge methods
    // ════════════════════════════════════════════════════════════════════

    /**
     * Connect the pipeline. Creates a new [AudioPipeline] with the given options.
     *
     * Options map:
     *   - `sampleRate` (Int, default 24000)
     *   - `channelCount` (Int, default 1)
     *   - `targetBufferMs` (Int, default 80)
     */
    fun connect(options: Map<String, Any?>, promise: expo.modules.kotlin.Promise) {
        try {
            // Tear down any existing pipeline first
            pipeline?.disconnect()

            val sampleRate = (options["sampleRate"] as? Number)?.toInt() ?: 24000
            val channelCount = (options["channelCount"] as? Number)?.toInt() ?: 1
            val targetBufferMs = (options["targetBufferMs"] as? Number)?.toInt() ?: 80
            val frequencyBandIntervalMs = (options["frequencyBandIntervalMs"] as? Number)?.toInt() ?: 100
            val bandConfig = options["frequencyBandConfig"] as? Map<*, *>
            val lowCrossoverHz = (bandConfig?.get("lowCrossoverHz") as? Number)?.toFloat() ?: 300f
            val highCrossoverHz = (bandConfig?.get("highCrossoverHz") as? Number)?.toFloat() ?: 2000f
            val audioMode = AudioMode.fromString(options["audioMode"] as? String)

            pipeline = AudioPipeline(
                context = context,
                sampleRate = sampleRate,
                channelCount = channelCount,
                targetBufferMs = targetBufferMs,
                frequencyBandIntervalMs = frequencyBandIntervalMs,
                lowCrossoverHz = lowCrossoverHz,
                highCrossoverHz = highCrossoverHz,
                audioMode = audioMode,
                listener = this
            )
            pipeline!!.connect()

            val result = Bundle().apply {
                putInt("sampleRate", sampleRate)
                putInt("channelCount", channelCount)
                putInt("targetBufferMs", targetBufferMs)
                putInt("frameSizeSamples", pipeline!!.frameSizeSamples)
            }
            promise.resolve(result)
        } catch (e: Exception) {
            Log.e(TAG, "connect failed", e)
            promise.reject("PIPELINE_CONNECT_ERROR", e.message ?: "Unknown error", e)
        }
    }

    /**
     * Push base64-encoded PCM audio into the jitter buffer (async — resolves Promise).
     *
     * Options map:
     *   - `audio` (String) — base64-encoded PCM16 LE data
     *   - `turnId` (String) — conversation turn identifier
     *   - `isFirstChunk` (Boolean, default false)
     *   - `isLastChunk` (Boolean, default false)
     */
    fun pushAudio(options: Map<String, Any?>, promise: expo.modules.kotlin.Promise) {
        try {
            val audio = options["audio"] as? String
                ?: throw IllegalArgumentException("Missing 'audio' field")
            val turnId = options["turnId"] as? String
                ?: throw IllegalArgumentException("Missing 'turnId' field")
            val isFirstChunk = options["isFirstChunk"] as? Boolean ?: false
            val isLastChunk = options["isLastChunk"] as? Boolean ?: false

            val p = pipeline
                ?: throw IllegalStateException("Pipeline not connected")
            p.pushAudio(audio, turnId, isFirstChunk, isLastChunk)
            promise.resolve(null)
        } catch (e: Exception) {
            Log.e(TAG, "pushAudio failed", e)
            promise.reject("PIPELINE_PUSH_ERROR", e.message ?: "Unknown error", e)
        }
    }

    /**
     * Push base64-encoded PCM audio synchronously (Function, not AsyncFunction).
     * No Promise overhead — designed for the hot path.
     *
     * Same options as [pushAudio].
     */
    fun pushAudioSync(options: Map<String, Any?>): Boolean {
        return try {
            val audio = options["audio"] as? String ?: return false
            val turnId = options["turnId"] as? String ?: return false
            val isFirstChunk = options["isFirstChunk"] as? Boolean ?: false
            val isLastChunk = options["isLastChunk"] as? Boolean ?: false

            pipeline?.pushAudio(audio, turnId, isFirstChunk, isLastChunk)
            true
        } catch (e: Exception) {
            Log.e(TAG, "pushAudioSync failed", e)
            false
        }
    }

    /**
     * Disconnect the pipeline. Tears down AudioTrack, write thread, etc.
     */
    fun disconnect(promise: expo.modules.kotlin.Promise) {
        try {
            pipeline?.disconnect()
            pipeline = null
            promise.resolve(null)
        } catch (e: Exception) {
            Log.e(TAG, "disconnect failed", e)
            promise.reject("PIPELINE_DISCONNECT_ERROR", e.message ?: "Unknown error", e)
        }
    }

    /**
     * Invalidate the current turn — discards stale audio in the jitter buffer.
     *
     * Options map:
     *   - `turnId` (String) — the new turn identifier
     */
    fun invalidateTurn(options: Map<String, Any?>, promise: expo.modules.kotlin.Promise) {
        try {
            val turnId = options["turnId"] as? String
                ?: throw IllegalArgumentException("Missing 'turnId' field")

            pipeline?.invalidateTurn(turnId)
            promise.resolve(null)
        } catch (e: Exception) {
            Log.e(TAG, "invalidateTurn failed", e)
            promise.reject("PIPELINE_INVALIDATE_ERROR", e.message ?: "Unknown error", e)
        }
    }

    /**
     * Get current pipeline telemetry as a Bundle (returned to JS as a map).
     */
    fun getTelemetry(): Bundle {
        return pipeline?.getTelemetry() ?: Bundle().apply {
            putString("state", PipelineState.IDLE.value)
        }
    }

    /**
     * Get current pipeline state string.
     */
    fun getState(): String {
        return pipeline?.getState()?.value ?: PipelineState.IDLE.value
    }

    /**
     * Current platform output latency in milliseconds. Returns 0 if not connected.
     */
    fun outputLatencyMs(): Double {
        return pipeline?.outputLatencyMs() ?: 0.0
    }

    /**
     * Log AudioTrack health — called from the device callback to capture
     * track state at the moment of a route change.
     */
    fun logAudioTrackHealth(trigger: String) {
        pipeline?.logTrackHealth(trigger) ?: Log.d(TAG, "logAudioTrackHealth($trigger) — no pipeline connected")
    }

    /**
     * Destroy the integration — called from OnDestroy / destroy().
     */
    fun destroy() {
        pipeline?.disconnect()
        pipeline = null
    }

    // ════════════════════════════════════════════════════════════════════
    // PipelineListener implementation → Expo bridge events
    // ════════════════════════════════════════════════════════════════════

    override fun onStateChanged(state: PipelineState) {
        sendEvent(EVENT_STATE_CHANGED, Bundle().apply {
            putString("state", state.value)
        })
    }

    override fun onPlaybackStarted(turnId: String) {
        sendEvent(EVENT_PLAYBACK_STARTED, Bundle().apply {
            putString("turnId", turnId)
        })
    }

    override fun onError(code: String, message: String) {
        sendEvent(EVENT_ERROR, Bundle().apply {
            putString("code", code)
            putString("message", message)
        })
    }

    override fun onZombieDetected(playbackHead: Long, stalledMs: Long) {
        sendEvent(EVENT_ZOMBIE_DETECTED, Bundle().apply {
            putLong("playbackHead", playbackHead)
            putLong("stalledMs", stalledMs)
        })
    }

    override fun onUnderrun(count: Int) {
        sendEvent(EVENT_UNDERRUN, Bundle().apply {
            putInt("count", count)
        })
    }

    override fun onDrained(turnId: String) {
        sendEvent(EVENT_DRAINED, Bundle().apply {
            putString("turnId", turnId)
        })
    }

    override fun onPlaybackStopped(turnId: String) {
        sendEvent(EVENT_PLAYBACK_STOPPED, Bundle().apply {
            putString("turnId", turnId)
        })
    }

    override fun onAudioFocusLost() {
        sendEvent(EVENT_AUDIO_FOCUS_LOST, Bundle())
    }

    override fun onAudioFocusResumed() {
        sendEvent(EVENT_AUDIO_FOCUS_RESUMED, Bundle())
    }

    override fun onFrequencyBands(low: Float, mid: Float, high: Float) {
        sendEvent(EVENT_FREQUENCY_BANDS, Bundle().apply {
            putFloat("low", low)
            putFloat("mid", mid)
            putFloat("high", high)
        })
    }

    // ── Helper ──────────────────────────────────────────────────────────

    private fun sendEvent(eventName: String, params: Bundle) {
        try {
            eventSender.sendExpoEvent(eventName, params)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to send event $eventName", e)
        }
    }
}

package expo.modules.audiostream.pipeline

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.util.Log
import expo.modules.audiostream.FrequencyBandAnalyzer
import expo.modules.audiostream.FrequencyBands
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// ────────────────────────────────────────────────────────────────────────────
// Public contracts
// ────────────────────────────────────────────────────────────────────────────

/** Pipeline states reported to JS via [PipelineListener.onStateChanged]. */
enum class PipelineState(val value: String) {
    IDLE("idle"),
    CONNECTING("connecting"),
    STREAMING("streaming"),
    DRAINING("draining"),
    ERROR("error");

    companion object {
        fun fromValue(value: String): PipelineState =
            entries.firstOrNull { it.value == value } ?: IDLE
    }
}

/** Listener interface — implemented by [PipelineIntegration] to bridge events to JS. */
interface PipelineListener {
    fun onStateChanged(state: PipelineState)
    fun onPlaybackStarted(turnId: String)
    fun onError(code: String, message: String)
    fun onZombieDetected(playbackHead: Long, stalledMs: Long)
    fun onUnderrun(count: Int)
    fun onDrained(turnId: String)
    fun onPlaybackStopped(turnId: String)
    fun onAudioFocusLost()
    fun onAudioFocusResumed()
    fun onFrequencyBands(low: Float, mid: Float, high: Float)
}

// ────────────────────────────────────────────────────────────────────────────
// AudioPipeline
// ────────────────────────────────────────────────────────────────────────────

/**
 * Controls how pipeline playback coexists with audio from other apps.
 * Mirrors the `PipelineAudioMode` TS type.
 */
enum class AudioMode {
    /** No focus request — playback mixes freely with other audio. */
    MIX_WITH_OTHERS,

    /** Request transient focus with ducking — others lower volume but keep playing. */
    DUCK_OTHERS,

    /** Request exclusive focus — others pause. */
    DO_NOT_MIX;

    companion object {
        fun fromString(value: String?): AudioMode = when (value) {
            "duckOthers" -> DUCK_OTHERS
            "doNotMix"   -> DO_NOT_MIX
            else         -> MIX_WITH_OTHERS  // default includes null, "mixWithOthers", and unknown
        }
    }
}

/**
 * Core orchestrator for the native audio pipeline.
 *
 * Creates an [AudioTrack] whose buffer size is derived from the device HAL's
 * `getMinBufferSize` (never hardcoded), a [JitterBuffer] ring, and a
 * **MAX_PRIORITY write thread** that loops `buffer.read() → track.write(BLOCKING)`.
 *
 * Key design points:
 *   - AudioTrack uses **USAGE_MEDIA + CONTENT_TYPE_SPEECH** (not
 *     VOICE_COMMUNICATION — avoids earpiece routing).
 *   - AudioTrack stays alive for the entire session, writing silence when idle.
 *     This avoids 50–100 ms restart latency.
 *   - Config is **immutable per session** — tear down and rebuild to change
 *     sample rate.
 *   - [turnLock] synchronizes [pushAudio] and [invalidateTurn] to prevent
 *     interleaved buffer.reset + buffer.write.
 *   - [disconnect] calls `track.stop()` to unblock WRITE_BLOCKING before
 *     joining the write thread, preventing the race where cleanup releases a
 *     track the write thread still holds.
 *   - [setState] dispatches listener callbacks to the main thread when called
 *     from the bridge thread.
 *   - Underrun events are debounced (fire once per new underrun, not per
 *     silence frame).
 */
class AudioPipeline(
    private val context: Context,
    private val sampleRate: Int,
    private val channelCount: Int,
    private val targetBufferMs: Int,
    private val frequencyBandIntervalMs: Int = 100,
    private val lowCrossoverHz: Float = 300f,
    private val highCrossoverHz: Float = 2000f,
    private val audioMode: AudioMode = AudioMode.MIX_WITH_OTHERS,
    private val listener: PipelineListener
) {
    companion object {
        private const val TAG = "AudioPipeline"

        /** Track buffer = 4× frame size for scheduling headroom. */
        private const val TRACK_BUFFER_MULTIPLIER = 4

        /** How often (ms) the zombie-detection daemon checks playbackHeadPosition. */
        private const val ZOMBIE_POLL_INTERVAL_MS = 2000L

        /** If playback head hasn't moved for this long, declare zombie. */
        private const val ZOMBIE_STALL_THRESHOLD_MS = 5000L

        /** Minimum volume level (0–15) enforced by VolumeGuard on STREAM_MUSIC. */
        private const val MIN_VOLUME_LEVEL = 1
    }

    // ── Derived audio constants ─────────────────────────────────────────
    private val channelMask =
        if (channelCount == 1) AudioFormat.CHANNEL_OUT_MONO
        else AudioFormat.CHANNEL_OUT_STEREO

    /** Minimum buffer size in bytes reported by the device HAL. */
    private val minBufferBytes: Int = run {
        val size = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (size <= 0) {
            Log.e(TAG, "getMinBufferSize returned $size " +
                "(sampleRate=$sampleRate, channels=$channelCount). " +
                "Falling back to 20ms frame.")
            // Fallback: 20ms worth of 16-bit samples
            (sampleRate * channelCount * 2) / 50  // 2 bytes per sample, 50 = 1000/20
        } else {
            size
        }
    }

    /** Number of 16-bit samples per "frame" (one HAL buffer). */
    val frameSizeSamples: Int = minBufferBytes / 2   // 2 bytes per short

    /** Track buffer in bytes — 4× frame for scheduling headroom. */
    private val trackBufferBytes = minBufferBytes * TRACK_BUFFER_MULTIPLIER

    // ── Core components ─────────────────────────────────────────────────
    private var audioTrack: AudioTrack? = null
    private var jitterBuffer: JitterBuffer? = null

    // ── Threading ───────────────────────────────────────────────────────
    private var writeThread: Thread? = null
    private val running = AtomicBoolean(false)

    // ── Turn management ─────────────────────────────────────────────────
    private val turnLock = ReentrantLock()
    @Volatile private var currentTurnId: String? = null
    @Volatile private var isFirstChunkOfTurn = true
    @Volatile private var playbackStartedForTurn = false

    /** Set by pushAudio on first chunk; consumed by writeLoop to flush stale silence from AudioTrack. */
    private val pendingFlush = AtomicBoolean(false)

    // ── Audio focus ─────────────────────────────────────────────────────
    private val audioManager: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val hasAudioFocus = AtomicBoolean(false)
    private val audioFocusLost = AtomicBoolean(false)

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                Log.d(TAG, "Audio focus gained")
                audioFocusLost.set(false)
                hasAudioFocus.set(true)
                listener.onAudioFocusResumed()
            }
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                Log.d(TAG, "Audio focus lost: $focusChange")
                audioFocusLost.set(true)
                // Don't release focus — keep writing silence so track stays alive
                listener.onAudioFocusLost()
            }
        }
    }

    // ── Zombie detection ────────────────────────────────────────────────
    private var zombieThread: Thread? = null
    private var lastPlaybackHead: Long = 0
    private var lastHeadChangeTime: Long = System.currentTimeMillis()

    // ── VolumeGuard ─────────────────────────────────────────────────────
    private var volumeObserver: ContentObserver? = null

    // ── Underrun debounce ───────────────────────────────────────────────
    private var lastReportedUnderrunCount = 0

    /**
     * Pending PlaybackStopped runnable scheduled on [mainHandler] — cancelled
     * on new turn / invalidateTurn / disconnect. All mutations of this field
     * MUST happen on the main thread to avoid races with the timer firing.
     */
    private var pendingPlaybackStoppedRunnable: Runnable? = null

    // ── Frequency band analysis ──────────────────────────────────────
    private var frequencyBandAnalyzer: FrequencyBandAnalyzer? = null
    private var frequencyBandExecutor: java.util.concurrent.ScheduledExecutorService? = null
    @Volatile private var lastEmittedBands: FrequencyBands? = null

    // ── State ───────────────────────────────────────────────────────────
    @Volatile private var state: PipelineState = PipelineState.IDLE
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Telemetry (atomics — safe to read from any thread) ──────────────
    val totalPushCalls = AtomicLong(0)
    val totalPushBytes = AtomicLong(0)
    val totalWriteLoops = AtomicLong(0)
    /** Frames successfully written to AudioTrack (one frame per sample-time across all channels). */
    private val framesWritten = AtomicLong(0)

    // ════════════════════════════════════════════════════════════════════
    // Connect / Disconnect
    // ════════════════════════════════════════════════════════════════════

    /**
     * Build the AudioTrack, JitterBuffer, start the write thread, request
     * audio focus, and install VolumeGuard + zombie detection.
     */
    fun connect() {
        if (running.get()) {
            Log.w(TAG, "connect() called while already running — ignoring")
            return
        }
        setState(PipelineState.CONNECTING)

        try {
            // ── 1. JitterBuffer ─────────────────────────────────────────
            jitterBuffer = JitterBuffer(
                sampleRate = sampleRate,
                channels = channelCount,
                targetBufferMs = targetBufferMs
            )

            // ── 2. AudioTrack ───────────────────────────────────────────
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()

            val audioFormat = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(channelMask)
                .build()

            audioTrack = AudioTrack.Builder()
                .setAudioAttributes(audioAttributes)
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(trackBufferBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            audioTrack!!.play()
            Log.d(TAG, "AudioTrack created and started — playState=${audioTrack!!.playState}, " +
                    "state=${audioTrack!!.state}, sampleRate=$sampleRate, " +
                    "bufferBytes=$trackBufferBytes, minBufferBytes=$minBufferBytes")

            // ── 3. Audio focus ──────────────────────────────────────────
            requestAudioFocus()

            // ── 4. Write thread ─────────────────────────────────────────
            running.set(true)
            writeThread = Thread(::writeLoop, "AudioPipeline-Writer").apply {
                priority = Thread.MAX_PRIORITY
                isDaemon = false
                start()
            }

            // ── 5. Zombie detection daemon ──────────────────────────────
            startZombieDetection()

            // ── 6. VolumeGuard ──────────────────────────────────────────
            installVolumeGuard()

            // ── 7. Reset telemetry ──────────────────────────────────────
            resetTelemetry()

            // ── 8. Frequency band analyzer ──────────────────────────
            frequencyBandAnalyzer = FrequencyBandAnalyzer(
                sampleRate = sampleRate,
                lowCrossoverHz = lowCrossoverHz,
                highCrossoverHz = highCrossoverHz
            )
            startFrequencyBandTimer()

            setState(PipelineState.IDLE)
            Log.d(TAG, "Connected — sampleRate=$sampleRate ch=$channelCount " +
                    "frameSamples=$frameSizeSamples targetBuffer=${targetBufferMs}ms")
        } catch (e: Exception) {
            Log.e(TAG, "connect() failed", e)
            setState(PipelineState.ERROR)
            disconnect()
            throw e
        }
    }

    /**
     * Tear down the pipeline.
     *
     * Calls `track.stop()` **first** to unblock the write thread's
     * `WRITE_BLOCKING` call, then joins the thread.
     */
    fun disconnect() {
        // Cancel any pending PlaybackStopped dispatch before tearing down.
        cancelPendingPlaybackStopped()

        running.set(false)

        // Stop zombie detection
        zombieThread?.interrupt()
        zombieThread = null

        // Stop frequency band timer
        frequencyBandExecutor?.shutdownNow()
        frequencyBandExecutor = null
        frequencyBandAnalyzer = null
        lastEmittedBands = null

        // Remove VolumeGuard
        removeVolumeGuard()

        // Abandon audio focus
        abandonAudioFocus()

        // Stop AudioTrack to unblock WRITE_BLOCKING
        try {
            audioTrack?.stop()
        } catch (e: IllegalStateException) {
            Log.w(TAG, "AudioTrack.stop() failed — may already be stopped", e)
        }

        // Join write thread (now unblocked)
        writeThread?.let { thread ->
            try {
                thread.join(2000)
                if (thread.isAlive) {
                    Log.w(TAG, "Write thread did not exit in time — interrupting")
                    thread.interrupt()
                    thread.join(1000)
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        writeThread = null

        // Release AudioTrack
        try {
            audioTrack?.release()
        } catch (e: Exception) {
            Log.w(TAG, "AudioTrack.release() failed", e)
        }
        audioTrack = null

        jitterBuffer = null
        currentTurnId = null

        setState(PipelineState.IDLE)
        Log.d(TAG, "Disconnected")
    }

    // ════════════════════════════════════════════════════════════════════
    // Push audio (bridge thread → jitter buffer)
    // ════════════════════════════════════════════════════════════════════

    /**
     * Decode a base64-encoded PCM16 chunk and write it into the jitter buffer.
     *
     * @param base64Audio Base64-encoded PCM 16-bit LE audio data.
     * @param turnId      Conversation turn identifier.
     * @param isFirstChunk True if this is the first chunk of a new turn.
     * @param isLastChunk  True if this is the final chunk of the current turn.
     */
    fun pushAudio(base64Audio: String, turnId: String, isFirstChunk: Boolean, isLastChunk: Boolean) {
        val buf = jitterBuffer ?: run {
            listener.onError("NOT_CONNECTED", "Pipeline not connected")
            return
        }

        turnLock.withLock {
            // ── Turn boundary handling ──────────────────────────────────
            if (isFirstChunk || currentTurnId != turnId) {
                buf.reset()
                currentTurnId = turnId
                this.isFirstChunkOfTurn = true
                playbackStartedForTurn = false
                lastReportedUnderrunCount = 0
                // Signal write loop to flush stale silence from AudioTrack
                // so real audio plays immediately without waiting behind queued silence.
                pendingFlush.set(true)
                setState(PipelineState.STREAMING)
                frequencyBandAnalyzer?.reset()
                cancelPendingPlaybackStopped()
            }

            // ── Decode base64 → PCM shorts ──────────────────────────────
            val bytes: ByteArray = try {
                Base64.decode(base64Audio, Base64.DEFAULT)
            } catch (e: Exception) {
                listener.onError("DECODE_ERROR", "Base64 decode failed: ${e.message}")
                return
            }

            val shortBuffer = ByteBuffer.wrap(bytes)
                .order(ByteOrder.LITTLE_ENDIAN)
                .asShortBuffer()
            val samples = ShortArray(shortBuffer.remaining())
            shortBuffer.get(samples)

            // ── Write into jitter buffer ────────────────────────────────
            buf.write(samples)

            // ── Telemetry ───────────────────────────────────────────────
            totalPushCalls.incrementAndGet()
            totalPushBytes.addAndGet(bytes.size.toLong())

            // ── End-of-stream ───────────────────────────────────────────
            if (isLastChunk) {
                buf.markEndOfStream()
                setState(PipelineState.DRAINING)
            }
        }
    }

    /**
     * Invalidate the current turn. Resets the jitter buffer so stale audio
     * is discarded immediately. Safe to call from any thread.
     */
    fun invalidateTurn(newTurnId: String) {
        turnLock.withLock {
            jitterBuffer?.reset()
            currentTurnId = newTurnId
            isFirstChunkOfTurn = true
            playbackStartedForTurn = false
            lastReportedUnderrunCount = 0
            setState(PipelineState.IDLE)
            frequencyBandAnalyzer?.reset()
            cancelPendingPlaybackStopped()
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // State & Telemetry
    // ════════════════════════════════════════════════════════════════════

    fun getState(): PipelineState = state

    fun getTelemetry(): Bundle {
        val buf = jitterBuffer
        val bundle = Bundle().apply {
            putString("state", state.value)
            putInt("bufferMs", buf?.bufferedMs() ?: 0)
            putInt("bufferSamples", buf?.availableSamples() ?: 0)
            putBoolean("primed", buf?.isPrimed() ?: false)
            putLong("totalWritten", buf?.totalWritten?.get() ?: 0)
            putLong("totalRead", buf?.totalRead?.get() ?: 0)
            putInt("underrunCount", buf?.underrunCount?.get() ?: 0)
            putInt("peakLevel", buf?.peakLevel?.get() ?: 0)
            putLong("totalPushCalls", totalPushCalls.get())
            putLong("totalPushBytes", totalPushBytes.get())
            putLong("totalWriteLoops", totalWriteLoops.get())
            putString("turnId", currentTurnId ?: "")
        }
        return bundle
    }

    /**
     * Current platform output latency in milliseconds — i.e., how long after
     * a sample is written before it physically leaves the speaker.
     *
     * Uses [AudioTrack.getTimestamp] to compute frames still in flight, then
     * converts to ms. Falls back to a conservative HAL-buffer estimate when
     * the timestamp call returns false (notably during initial buffering or
     * on bad audio routes).
     *
     * Returns 0 if the pipeline is not connected.
     */
    fun outputLatencyMs(): Double {
        val track = audioTrack ?: return 0.0
        val ts = android.media.AudioTimestamp()
        val ok = try {
            track.getTimestamp(ts)
        } catch (e: IllegalStateException) {
            false
        }
        if (ok) {
            val inFlight = framesWritten.get() - ts.framePosition
            if (inFlight > 0) {
                return (inFlight.toDouble() / sampleRate.toDouble()) * 1000.0
            }
            return 0.0
        }
        // Fallback: assume the HAL holds ~2× minBuffer worth of frames.
        val fallbackFrames = (minBufferBytes / 2 / channelCount) * 2
        return (fallbackFrames.toDouble() / sampleRate.toDouble()) * 1000.0
    }

    // ════════════════════════════════════════════════════════════════════
    // Write loop (runs on MAX_PRIORITY thread)
    // ════════════════════════════════════════════════════════════════════

    private fun writeLoop() {
        Log.d(TAG, "Write thread started — frameSizeSamples=$frameSizeSamples, trackBufferBytes=$trackBufferBytes")
        val frame = ShortArray(frameSizeSamples)

        while (running.get()) {
            val track = audioTrack ?: break
            val buf = jitterBuffer ?: break

            // Flush stale silence from AudioTrack when a new turn starts.
            // This prevents the real audio from queuing behind silence frames
            // that were written while idle.
            if (pendingFlush.compareAndSet(true, false)) {
                Log.d(TAG, "Flushing AudioTrack for new turn (head=${track.playbackHeadPosition})")
                track.pause()
                track.flush()
                track.play()
            }

            // Read from jitter buffer (silence if not primed or underrun)
            buf.read(frame)

            // If audio focus is lost, overwrite with silence
            if (audioFocusLost.get()) {
                frame.fill(0)
            }

            // Analyze frequency bands on the raw Int16 samples.
            // Only feed real audio (streaming/draining) — not silence frames
            // written while idle/priming, which would dilute RMS energy.
            if (!audioFocusLost.get() && (state == PipelineState.STREAMING || state == PipelineState.DRAINING)) {
                frequencyBandAnalyzer?.processSamples(frame, frame.size)
            }

            // Write to AudioTrack (BLOCKING — will park thread until space available)
            try {
                val written = track.write(frame, 0, frame.size, AudioTrack.WRITE_BLOCKING)

                if (written < 0) {
                    val errorName = when (written) {
                        AudioTrack.ERROR_INVALID_OPERATION -> "ERROR_INVALID_OPERATION"
                        AudioTrack.ERROR_BAD_VALUE -> "ERROR_BAD_VALUE"
                        AudioTrack.ERROR_DEAD_OBJECT -> "ERROR_DEAD_OBJECT"
                        AudioTrack.ERROR -> "ERROR"
                        else -> "UNKNOWN($written)"
                    }
                    Log.e(TAG, "AudioTrack.write returned error: $errorName ($written), " +
                            "playState=${track.playState}, trackState=${track.state}")
                    setState(PipelineState.ERROR)
                    listener.onError("WRITE_ERROR", "AudioTrack.write returned $errorName ($written)")
                    break
                }
                // Track frames written for output-latency computation.
                // `written` is Int16-sample count; divide by channelCount for frames.
                framesWritten.addAndGet((written / channelCount).toLong())
            } catch (e: IllegalStateException) {
                // Track was stopped/released — expected during disconnect
                if (running.get()) {
                    Log.e(TAG, "AudioTrack.write threw in running state", e)
                    setState(PipelineState.ERROR)
                    listener.onError("WRITE_ERROR", e.message ?: "AudioTrack write error")
                }
                break
            }

            totalWriteLoops.incrementAndGet()

            // ── Playback-started event (once per turn) ──────────────────
            if (!playbackStartedForTurn && buf.isPrimed() && currentTurnId != null) {
                playbackStartedForTurn = true
                listener.onPlaybackStarted(currentTurnId!!)
            }

            // ── Underrun debounce ───────────────────────────────────────
            val currentUnderruns = buf.underrunCount.get()
            if (currentUnderruns > lastReportedUnderrunCount) {
                lastReportedUnderrunCount = currentUnderruns
                listener.onUnderrun(currentUnderruns)
            }

            // ── Drain detection ─────────────────────────────────────────
            if (buf.isDrained() && state == PipelineState.DRAINING) {
                currentTurnId?.let { tid ->
                    listener.onDrained(tid)
                    schedulePlaybackStopped(tid)
                }
                setState(PipelineState.IDLE)
            }
        }

        Log.d(TAG, "Write thread exiting")
    }

    // ════════════════════════════════════════════════════════════════════
    // Audio focus
    // ════════════════════════════════════════════════════════════════════

    private fun requestAudioFocus() {
        when (audioMode) {
            AudioMode.MIX_WITH_OTHERS -> {
                // No focus request — we coexist silently with other apps.
                // Mark as "has focus" so the write loop proceeds unconditionally.
                hasAudioFocus.set(true)
                audioFocusLost.set(false)
                Log.d(TAG, "Audio focus skipped (mixWithOthers)")
            }
            AudioMode.DUCK_OTHERS -> {
                val result = audioManager.requestAudioFocus(
                    focusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                )
                hasAudioFocus.set(result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                if (!hasAudioFocus.get()) {
                    Log.w(TAG, "Audio focus request (duckOthers) denied")
                }
            }
            AudioMode.DO_NOT_MIX -> {
                val result = audioManager.requestAudioFocus(
                    focusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                )
                hasAudioFocus.set(result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                if (!hasAudioFocus.get()) {
                    Log.w(TAG, "Audio focus request (doNotMix) denied")
                }
            }
        }
    }

    private fun abandonAudioFocus() {
        if (audioMode == AudioMode.MIX_WITH_OTHERS) {
            // No focus was ever requested — nothing to abandon.
            hasAudioFocus.set(false)
            audioFocusLost.set(false)
            return
        }
        audioManager.abandonAudioFocus(focusChangeListener)
        hasAudioFocus.set(false)
        audioFocusLost.set(false)
    }

    // ════════════════════════════════════════════════════════════════════
    // Zombie AudioTrack detection
    // ════════════════════════════════════════════════════════════════════

    private fun startZombieDetection() {
        lastPlaybackHead = audioTrack?.playbackHeadPosition?.toLong() ?: 0
        lastHeadChangeTime = System.currentTimeMillis()

        zombieThread = Thread({
            while (running.get() && !Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(ZOMBIE_POLL_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    break
                }

                val track = audioTrack ?: break
                val head = track.playbackHeadPosition.toLong()
                val now = System.currentTimeMillis()

                if (head != lastPlaybackHead) {
                    lastPlaybackHead = head
                    lastHeadChangeTime = now
                } else {
                    val stalledMs = now - lastHeadChangeTime
                    // Only flag zombie if we think we're actively streaming
                    if (stalledMs >= ZOMBIE_STALL_THRESHOLD_MS &&
                        (state == PipelineState.STREAMING || state == PipelineState.DRAINING)
                    ) {
                        Log.w(TAG, "Zombie AudioTrack detected! head=$head stalledMs=$stalledMs " +
                                "playState=${track.playState} trackState=${track.state} " +
                                "writeLoops=${totalWriteLoops.get()}")
                        listener.onZombieDetected(head, stalledMs)
                        // Reset the timer so we don't spam
                        lastHeadChangeTime = now
                    }
                }
            }
        }, "AudioPipeline-Zombie").apply {
            isDaemon = true
            start()
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Frequency band emission
    // ════════════════════════════════════════════════════════════════════

    private fun startFrequencyBandTimer() {
        val executor = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "AudioPipeline-FreqBands").apply { isDaemon = true }
        }
        executor.scheduleAtFixedRate({
            if (!running.get()) return@scheduleAtFixedRate
            val analyzer = frequencyBandAnalyzer ?: return@scheduleAtFixedRate
            val bands = if (analyzer.hasData()) {
                analyzer.harvest().also { lastEmittedBands = it }
            } else {
                lastEmittedBands ?: return@scheduleAtFixedRate
            }
            listener.onFrequencyBands(bands.low, bands.mid, bands.high)
        }, frequencyBandIntervalMs.toLong(), frequencyBandIntervalMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
        frequencyBandExecutor = executor
    }

    // ════════════════════════════════════════════════════════════════════
    // VolumeGuard
    // ════════════════════════════════════════════════════════════════════

    private fun installVolumeGuard() {
        volumeObserver = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean) {
                val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                if (current < MIN_VOLUME_LEVEL) {
                    Log.d(TAG, "VolumeGuard: raising STREAM_MUSIC from $current to $MIN_VOLUME_LEVEL")
                    try {
                        audioManager.setStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            MIN_VOLUME_LEVEL,
                            0 // no flags — silent raise
                        )
                    } catch (e: SecurityException) {
                        Log.w(TAG, "VolumeGuard: setStreamVolume denied", e)
                    }
                }
            }
        }

        try {
            context.contentResolver.registerContentObserver(
                Settings.System.CONTENT_URI,
                true,
                volumeObserver!!
            )
        } catch (e: Exception) {
            Log.w(TAG, "VolumeGuard: failed to register ContentObserver", e)
            volumeObserver = null
        }
    }

    private fun removeVolumeGuard() {
        volumeObserver?.let {
            try {
                context.contentResolver.unregisterContentObserver(it)
            } catch (e: Exception) {
                Log.w(TAG, "VolumeGuard: failed to unregister", e)
            }
        }
        volumeObserver = null
    }

    // ════════════════════════════════════════════════════════════════════
    // Diagnostics (called from device callback via PipelineIntegration)
    // ════════════════════════════════════════════════════════════════════

    /**
     * Snapshot AudioTrack state at the moment of a route change.
     * This tells us whether the track survives the switch or silently dies.
     */
    fun logTrackHealth(trigger: String) {
        val track = audioTrack
        if (track == null) {
            Log.d(TAG, "[$trigger] AudioTrack health: track is null (pipeline not connected)")
            return
        }

        val playState = when (track.playState) {
            AudioTrack.PLAYSTATE_STOPPED -> "STOPPED"
            AudioTrack.PLAYSTATE_PAUSED -> "PAUSED"
            AudioTrack.PLAYSTATE_PLAYING -> "PLAYING"
            else -> "UNKNOWN(${track.playState})"
        }
        val trackState = when (track.state) {
            AudioTrack.STATE_UNINITIALIZED -> "UNINITIALIZED"
            AudioTrack.STATE_INITIALIZED -> "INITIALIZED"
            AudioTrack.STATE_NO_STATIC_DATA -> "NO_STATIC_DATA"
            else -> "UNKNOWN(${track.state})"
        }
        val head = track.playbackHeadPosition
        val buf = jitterBuffer
        val bufMs = buf?.bufferedMs() ?: -1
        val bufPrimed = buf?.isPrimed() ?: false

        Log.d(TAG, "[$trigger] AudioTrack health: playState=$playState, trackState=$trackState, " +
                "head=$head, pipelineState=${state.value}, running=${running.get()}, " +
                "bufferMs=$bufMs, primed=$bufPrimed, audioFocusLost=${audioFocusLost.get()}, " +
                "writeLoops=${totalWriteLoops.get()}")
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ════════════════════════════════════════════════════════════════════

    /**
     * Schedule a `PlaybackStopped` callback approximately [outputLatencyMs]
     * milliseconds after `Drained`. Cancels any previously pending dispatch.
     *
     * Called from the write thread; the actual cancellation/scheduling and
     * invocation happen on the main thread so we never race ourselves.
     */
    private fun schedulePlaybackStopped(turnId: String) {
        val latencyMs = outputLatencyMs().toLong()
        mainHandler.post {
            pendingPlaybackStoppedRunnable?.let { mainHandler.removeCallbacks(it) }

            val runnable = Runnable {
                pendingPlaybackStoppedRunnable = null
                listener.onPlaybackStopped(turnId)
            }
            pendingPlaybackStoppedRunnable = runnable

            if (latencyMs > 0) {
                mainHandler.postDelayed(runnable, latencyMs)
            } else {
                mainHandler.post(runnable)
            }
        }
    }

    /**
     * Cancel any pending PlaybackStopped dispatch. Posts to [mainHandler] so
     * all mutations of [pendingPlaybackStoppedRunnable] are on one thread.
     */
    private fun cancelPendingPlaybackStopped() {
        mainHandler.post {
            pendingPlaybackStoppedRunnable?.let { mainHandler.removeCallbacks(it) }
            pendingPlaybackStoppedRunnable = null
        }
    }

    private fun setState(newState: PipelineState) {
        if (state == newState) return
        state = newState
        // Dispatch to main thread if called from bridge/write thread
        if (Looper.myLooper() == Looper.getMainLooper()) {
            listener.onStateChanged(newState)
        } else {
            mainHandler.post { listener.onStateChanged(newState) }
        }
    }

    private fun resetTelemetry() {
        totalPushCalls.set(0)
        totalPushBytes.set(0)
        totalWriteLoops.set(0)
        framesWritten.set(0)
        jitterBuffer?.resetTelemetry()
    }
}

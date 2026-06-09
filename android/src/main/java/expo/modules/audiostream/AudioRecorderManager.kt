package expo.modules.audiostream

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.os.bundleOf
import expo.modules.kotlin.Promise
import java.util.concurrent.atomic.AtomicBoolean


class AudioRecorderManager(
    private val permissionUtils: PermissionUtils,
    private val audioDataEncoder: AudioDataEncoder,
    private val eventSender: EventSender,
    private val audioEffectsManager: AudioEffectsManager
) {
    private var audioRecord: AudioRecord? = null
    private var bufferSizeInBytes = 0   // AudioRecord internal ring buffer (>= getMinBufferSize)
    private var readSizeInBytes = 0     // Bytes to read per call (exactly one interval of audio)
    private var isRecording = AtomicBoolean(false)
    private val isPaused = AtomicBoolean(false)
    private var streamUuid: String? = null
    private var recordingThread: Thread? = null
    private var recordingStartTime: Long = 0
    private var totalRecordedTime: Long = 0
    private var totalDataSize = 0
    private var pausedDuration = 0L
    private var lastEmittedSize = 0L
    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioRecordLock = Any()

    // Flag to control whether actual audio data or silence is sent
    private var isSilent = false
    @Volatile private var micGain: Float = 1.0f
    private var frequencyBandAnalyzer: FrequencyBandAnalyzer? = null
    private val gainNormalizer = GainNormalizer()

    private lateinit var recordingConfig: RecordingConfig
    private var mimeType = "audio/wav"
    private var audioFormat: Int = AudioFormat.ENCODING_PCM_16BIT

    /**
     * Validates the recording state by checking permission and recording status
     * @param promise Promise to reject if validation fails
     * @param checkRecordingState Whether to check if recording is in progress
     * @param shouldRejectIfRecording Whether to reject if recording is in progress
     * @return True if validation passes, false otherwise
     */
    private fun validateRecordingState(
        promise: Promise? = null,
        checkRecordingState: Boolean = false,
        shouldRejectIfRecording: Boolean = true
    ): Boolean {
        // First check permission
        if (!permissionUtils.checkRecordingPermission()) {
            if (promise != null) {
                promise.reject("PERMISSION_DENIED", "Recording permission has not been granted", null)
            } else {
                throw SecurityException("Recording permission has not been granted")
            }
            return false
        }

        // Then check recording state if requested
        if (checkRecordingState) {
            val isActive = isRecording.get() && !isPaused.get()

            if (isActive && shouldRejectIfRecording && promise != null) {
                promise.resolve("Recording is already in progress")
                return false
            }

            return !isActive // Return true if not recording (validation passes)
        }

        return true // Permission check passed
    }

    @RequiresApi(Build.VERSION_CODES.R)
    fun startRecording(options: Map<String, Any?>, promise: Promise) {
        // Check permission and recording state
        if (!validateRecordingState(promise, checkRecordingState = true, shouldRejectIfRecording = true)) {
            return
        }

        // Initialize the recording configuration using the factory method
        val tempRecordingConfig = RecordingConfig.fromOptions(options)
        Log.d(Constants.TAG, "Initial recording configuration: $tempRecordingConfig")

        // Validate the recording configuration
        val configValidationResult = tempRecordingConfig.validate()
        if (configValidationResult != null) {
            promise.reject(configValidationResult.code, configValidationResult.message, null)
            return
        }

        // Get audio format configuration using the helper
        val formatConfig = audioDataEncoder.getAudioFormatConfig(tempRecordingConfig.encoding)

        // Check for any errors in the configuration
        if (formatConfig.error != null) {
            promise.reject("UNSUPPORTED_FORMAT", formatConfig.error, null)
            return
        }

        // Set the audio format
        audioFormat = formatConfig.audioFormat

        // Validate the audio format and get potentially updated config
        val formatValidationResult = validateAudioFormat(tempRecordingConfig, audioFormat, promise)
        if (formatValidationResult == null) {
            return
        }

        // Update with validated values
        audioFormat = formatValidationResult.first
        recordingConfig = formatValidationResult.second

        // Compute how many bytes correspond to the requested interval.
        val bytesPerSample = when (recordingConfig.encoding) {
            "pcm_8bit" -> 1
            "pcm_32bit" -> 4
            else -> 2
        }
        val intervalBytes = (recordingConfig.interval * recordingConfig.sampleRate *
                recordingConfig.channels * bytesPerSample / 1000).toInt()

        // readSizeInBytes = exactly one interval of audio; this is what we request
        // per read() call, giving us the cadence the caller asked for.
        readSizeInBytes = intervalBytes

        // AudioRecord's internal ring buffer must be >= getMinBufferSize.
        // Make it large enough to hold at least one full read, too.
        val channelConfig = if (recordingConfig.channels == 1) AudioFormat.CHANNEL_IN_MONO
            else AudioFormat.CHANNEL_IN_STEREO
        val minBuf = AudioRecord.getMinBufferSize(recordingConfig.sampleRate, channelConfig, audioFormat)
        bufferSizeInBytes = maxOf(intervalBytes, minBuf)
        Log.d(Constants.TAG, "Interval: ${recordingConfig.interval}ms, readSize: $readSizeInBytes, ringBuffer: $bufferSizeInBytes (minBuf=$minBuf)")

        // Initialize the AudioRecord if it's a new recording or if it's not currently paused
        if (audioRecord == null || !isPaused.get()) {
            Log.d(Constants.TAG, "AudioFormat: $audioFormat, BufferSize: $bufferSizeInBytes")

            audioRecord = createAudioRecord(tempRecordingConfig, audioFormat, promise)
            if (audioRecord == null) {
                return
            }
        }

        // Generate a unique ID for this recording stream
        streamUuid = java.util.UUID.randomUUID().toString()

        // AEC and other effects must be attached before startRecording() so the
        // hardware echo canceller processes audio from the very first captured frame.
        audioRecord?.let { audioEffectsManager.setupAudioEffects(it) }
        audioRecord?.startRecording()

        isPaused.set(false)
        isRecording.set(true)

        if (!isPaused.get()) {
            recordingStartTime =
                System.currentTimeMillis() // Only reset start time if it's not a resume
        }

        recordingThread = Thread { recordingProcess() }.apply { start() }

        // Create frequency band analyzer
        val bandConfig = options["frequencyBandConfig"] as? Map<*, *>
        frequencyBandAnalyzer = FrequencyBandAnalyzer(
            sampleRate = recordingConfig.sampleRate,
            lowCrossoverHz = (bandConfig?.get("lowCrossoverHz") as? Number)?.toFloat() ?: 300f,
            highCrossoverHz = (bandConfig?.get("highCrossoverHz") as? Number)?.toFloat() ?: 2000f
        )

        val result = bundleOf(
            "fileUri" to "",
            "channels" to recordingConfig.channels,
            "bitDepth" to when (recordingConfig.encoding) {
                "pcm_8bit" -> 8
                "pcm_16bit" -> 16
                "pcm_32bit" -> 32
                else -> 16 // Default to 16 if the encoding is not recognized
            },
            "sampleRate" to recordingConfig.sampleRate,
            "mimeType" to formatConfig.mimeType
        )
        promise.resolve(result)
    }

    /**
     * Common resource cleanup logic extracted to avoid duplication
     */
    private fun cleanupResources() {
        try {
            // Release audio effects
            audioEffectsManager.releaseAudioEffects()

            // Stop and release AudioRecord if exists
            if (audioRecord != null) {
                try {
                    if (audioRecord!!.state == AudioRecord.STATE_INITIALIZED) {
                        audioRecord!!.stop()
                    }
                } catch (e: Exception) {
                    Log.e(Constants.TAG, "Error stopping AudioRecord", e)
                } finally {
                    try {
                        audioRecord!!.release()
                    } catch (e: Exception) {
                        Log.e(Constants.TAG, "Error releasing AudioRecord", e)
                    }
                }
                audioRecord = null
            }

            // Interrupt and clear recording thread
            recordingThread?.interrupt()
            recordingThread = null

            // Always reset state
            isRecording.set(false)
            isPaused.set(false)
            totalRecordedTime = 0
            pausedDuration = 0
            totalDataSize = 0
            streamUuid = null
            frequencyBandAnalyzer = null
            lastEmittedSize = 0

            Log.d(Constants.TAG, "Audio resources cleaned up")
        } catch (e: Exception) {
            Log.e(Constants.TAG, "Error during resource cleanup", e)
        }
    }

    fun stopRecording(promise: Promise) {
        synchronized(audioRecordLock) {
            if (!isRecording.get()) {
                Log.e(Constants.TAG, "Recording is not active")
                promise.resolve(null)
                return
            }

            try {
                // Read any final audio data
                val audioData = ByteArray(bufferSizeInBytes)
                val bytesRead = audioRecord?.read(audioData, 0, bufferSizeInBytes) ?: -1
                Log.d(Constants.TAG, "Last Read $bytesRead bytes")
                if (bytesRead > 0) {
                    emitAudioData(audioData, bytesRead)
                }

                // Generate result before cleanup
                val bytesPerSample = when (recordingConfig.encoding) {
                    "pcm_8bit" -> 1
                    "pcm_16bit" -> 2
                    "pcm_32bit" -> 4
                    else -> 2
                }
                val byteRate = recordingConfig.sampleRate * recordingConfig.channels * bytesPerSample
                val duration = if (byteRate > 0) (totalDataSize.toLong() * 1000 / byteRate) else 0

                // Create result bundle
                val result = bundleOf(
                    "fileUri" to "",
                    "filename" to "",
                    "durationMs" to duration,
                    "channels" to recordingConfig.channels,
                    "bitDepth" to when (recordingConfig.encoding) {
                        "pcm_8bit" -> 8
                        "pcm_16bit" -> 16
                        "pcm_32bit" -> 32
                        else -> 16
                    },
                    "sampleRate" to recordingConfig.sampleRate,
                    "size" to totalDataSize.toLong(),
                    "mimeType" to mimeType
                )

                // Clean up all resources
                cleanupResources()

                // Resolve promise with the result
                promise.resolve(result)

            } catch (e: Exception) {
                Log.d(Constants.TAG, "Failed to stop recording", e)
                // Make sure to clean up even if there's an error
                cleanupResources()
                promise.reject("STOP_FAILED", "Failed to stop recording", e)
            }
        }
    }

    private fun recordingProcess() {
        Log.i(Constants.TAG, "Starting recording process, readSize=$readSizeInBytes, ringBuffer=$bufferSizeInBytes")
        val audioData = ByteArray(readSizeInBytes)
        var consecutiveErrors = 0

        try {
            while (isRecording.get() && !Thread.currentThread().isInterrupted) {
                if (isPaused.get()) {
                    try {
                        Thread.sleep(10)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        break
                    }
                    continue
                }

                val bytesRead = synchronized(audioRecordLock) {
                    audioRecord?.let {
                        if (it.state != AudioRecord.STATE_INITIALIZED) {
                            Log.e(Constants.TAG, "AudioRecord not initialized")
                            return@let -1
                        }
                        // Read exactly one interval's worth of audio.
                        // AudioRecord.read() blocks until readSizeInBytes are available.
                        it.read(audioData, 0, readSizeInBytes).also { bytes ->
                            if (bytes < 0) {
                                Log.e(Constants.TAG, "AudioRecord read error: $bytes")
                            }
                        }
                    } ?: -1
                }

                if (bytesRead > 0) {
                    consecutiveErrors = 0
                    gainNormalizer.apply(audioData, bytesRead)
                    totalDataSize += bytesRead
                    // Emit immediately — each read is one interval of audio
                    emitAudioData(audioData, bytesRead)
                } else if (bytesRead < 0) {
                    consecutiveErrors++
                    if (consecutiveErrors >= 10) {
                        Log.e(Constants.TAG, "Too many consecutive read errors ($consecutiveErrors), stopping")
                        emitRecordingError("READ_ERROR", "AudioRecord read failed after $consecutiveErrors consecutive errors", isFatal = true)
                        break
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(Constants.TAG, "Recording thread crashed", e)
            emitRecordingError("RECORDING_CRASH", e.message ?: "Recording thread unexpected error", isFatal = true)
        }
    }

    /**
     * Sends a recording error event to JS so the caller can react.
     */
    private fun emitRecordingError(
        code: String,
        message: String,
        isFatal: Boolean,
        autoResuming: Boolean = false
    ) {
        mainHandler.post {
            try {
                // Backward-compat: keep the error variant on AudioData for existing consumers
                eventSender.sendExpoEvent(
                    Constants.AUDIO_EVENT_NAME, bundleOf(
                        "error" to code,
                        "errorMessage" to message,
                        "streamUuid" to streamUuid
                    )
                )
                // Rich structured channel for new consumers
                eventSender.sendExpoEvent(
                    Constants.MICROPHONE_ERROR_EVENT_NAME, bundleOf(
                        "code" to code,
                        "message" to message,
                        "isFatal" to isFatal,
                        "autoResuming" to autoResuming
                    )
                )
            } catch (e: Exception) {
                Log.e(Constants.TAG, "Failed to send error event", e)
            }
        }
    }

    private fun emitAudioData(audioData: ByteArray, length: Int) {
        val dataToEncode = when {
            isSilent -> ByteArray(length)
            micGain != 1.0f -> applyMicGain(audioData, length, micGain)
            else -> audioData
        }

        val encodedBuffer = audioDataEncoder.encodeToBase64(dataToEncode)

        val from = lastEmittedSize
        val deltaSize = totalDataSize.toLong() - lastEmittedSize
        lastEmittedSize = totalDataSize.toLong()

        // Calculate position in milliseconds
        val positionInMs = (from * 1000) / (recordingConfig.sampleRate * recordingConfig.channels * (if (recordingConfig.encoding == "pcm_8bit") 8 else 16) / 8)

        // Calculate power level (using concise expression)
        val soundLevel = if (isSilent) -160.0f else audioDataEncoder.calculatePowerLevel(audioData, length)

        // Compute frequency bands
        val bands = if (isSilent) {
            FrequencyBands.ZERO
        } else {
            frequencyBandAnalyzer?.let { analyzer ->
                analyzer.processSamplesFromBytes(audioData, length)
                analyzer.harvest()
            }
        }

        mainHandler.post {
            try {
                eventSender.sendExpoEvent(
                    Constants.AUDIO_EVENT_NAME, bundleOf(
                        "fileUri" to "",
                        "lastEmittedSize" to from,
                        "encoded" to encodedBuffer,
                        "deltaSize" to length,
                        "position" to positionInMs,
                        "mimeType" to mimeType,
                        "soundLevel" to soundLevel,
                        "frequencyBands" to bundleOf(
                            "low" to (bands?.low ?: 0f),
                            "mid" to (bands?.mid ?: 0f),
                            "high" to (bands?.high ?: 0f)
                        ),
                        "totalSize" to totalDataSize.toLong(),
                        "streamUuid" to streamUuid
                    )
                )
            } catch (e: Exception) {
                Log.e(Constants.TAG, "Failed to send event", e)
            }
        }
    }

    /**
     * Releases all resources used by the recorder.
     * Should be called when the module is being destroyed.
     */
    fun release() {
        try {
            // If recording is active, stop it properly
            if (isRecording.get()) {
                // Create a simple promise to handle the result without callback
                val dummyPromise = object : Promise {
                    override fun resolve(value: Any?) {
                        Log.d(Constants.TAG, "Recording stopped during release")
                    }

                    override fun reject(code: String, message: String?, cause: Throwable?) {
                        Log.e(Constants.TAG, "Error stopping recording during release: $message", cause)
                    }
                }

                // Use stopRecording which will handle full cleanup
                stopRecording(dummyPromise)
            } else {
                // Not recording, just clean up resources
                cleanupResources()
            }

            Log.d(Constants.TAG, "AudioRecorderManager fully released")
        } catch (e: Exception) {
            Log.e(Constants.TAG, "Error during AudioRecorderManager release", e)
        }
    }

    /**
     * Toggles between sending actual audio data and silence
     */
    fun setMicrophoneGain(gain: Float) {
        micGain = gain.coerceIn(0.0f, 1.0f)
    }

    private fun applyMicGain(data: ByteArray, length: Int, gain: Float): ByteArray {
        val result = ByteArray(length)
        var i = 0
        while (i + 1 < length) {
            val lo = data[i].toInt() and 0xFF
            val hi = data[i + 1].toInt()       // sign-extends
            val sample = (hi shl 8) or lo      // little-endian Int16
            val scaled = (sample * gain).toInt().coerceIn(-32768, 32767)
            result[i]     = (scaled and 0xFF).toByte()
            result[i + 1] = (scaled shr 8).toByte()
            i += 2
        }
        return result
    }

    fun toggleSilence(isSilent: Boolean) {
        this.isSilent = isSilent
        Log.d(Constants.TAG, "Silence mode toggled: $isSilent")
    }

    /**
     * Creates an AudioRecord instance with the given configuration
     * @param config The recording configuration
     * @param audioFormat The audio format to use
     * @param promise Promise to reject if initialization fails
     * @return The created AudioRecord instance or null if failed
     */
    private fun createAudioRecord(
        config: RecordingConfig,
        audioFormat: Int,
        promise: Promise
    ): AudioRecord? {
        // Double check permission again directly before creating AudioRecord
        if (!permissionUtils.checkRecordingPermission()) {
            promise.reject("PERMISSION_DENIED", "Recording permission has not been granted", null)
            return null
        }

        // VOICE_COMMUNICATION enables platform-managed AEC (echo cancellation happens at
        // the HAL level, not just via the explicit AcousticEchoCanceler effect).
        // VOICE_RECOGNITION intentionally bypasses platform AEC per the Android CDD,
        // making hardware echo cancellation ineffective regardless of AudioEffectsManager.
        val audioSource = MediaRecorder.AudioSource.VOICE_COMMUNICATION

        val record = AudioRecord(
            audioSource,
            config.sampleRate,
            if (config.channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO,
            audioFormat,
            bufferSizeInBytes
        )

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            promise.reject(
                "INITIALIZATION_FAILED",
                "Failed to initialize the audio recorder",
                null
            )
            return null
        }

        return record
    }

    /**
     * Validates the audio format for the given recording configuration
     * @param config The recording configuration
     * @param initialFormat The initial audio format to validate
     * @param promise Promise to reject if no supported format is found
     * @return A pair containing the validated audio format and potentially updated recording config
     */
    private fun validateAudioFormat(
        config: RecordingConfig,
        initialFormat: Int,
        promise: Promise
    ): Pair<Int, RecordingConfig>? {
        var audioFormat = initialFormat
        var updatedConfig = config

        // Check if selected audio format is supported
        if (!audioDataEncoder.isAudioFormatSupported(config.sampleRate, config.channels, audioFormat, permissionUtils)) {
            Log.e(Constants.TAG, "Selected audio format not supported, falling back to 16-bit PCM")
            audioFormat = AudioFormat.ENCODING_PCM_16BIT

            if (!audioDataEncoder.isAudioFormatSupported(config.sampleRate, config.channels, audioFormat, permissionUtils)) {
                promise.reject("INITIALIZATION_FAILED", "Failed to initialize audio recorder with any supported format", null)
                return null
            }

            updatedConfig = config.copy(encoding = "pcm_16bit")
        }

        return Pair(audioFormat, updatedConfig)
    }
}

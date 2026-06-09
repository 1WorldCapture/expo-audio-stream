package expo.modules.audiostream

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import expo.modules.interfaces.permissions.Permissions
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.audiostream.pipeline.PipelineIntegration



class ExpoPlayAudioStreamModule : Module(), EventSender {
    private lateinit var audioRecorderManager: AudioRecorderManager
    private lateinit var audioManager: AudioManager
    private lateinit var pipelineIntegration: PipelineIntegration
    private lateinit var communicationAudioManager: CommunicationAudioManager

    // Ensure callbacks are delivered on the main thread
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    private val reportedGroups = mutableSetOf<String>()

    /** Map every device type to a logical group key */
    private fun groupKey(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "BLUETOOTH"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET   -> "WIRED"
        else -> type.toString() // fallback, treats every other type separately
    }

    // We care about these types – includes both SCO and A2DP but we will collapse them into one group
    private val interestingTypes = setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET
    )

    private val audioCallCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            val descriptions = addedDevices?.map { "${it.productName} (type=${it.type})" } ?: emptyList()
            Log.d("ExpoAudioCallback", "onAudioDevicesAdded: $descriptions")

            val firstOfGroup = addedDevices?.filter { d ->
                d.type in interestingTypes && reportedGroups.add(groupKey(d.type))
            }
            if (firstOfGroup?.isNotEmpty()==true) {
                val matched = firstOfGroup.map { "${it.productName} (type=${it.type})" }
                Log.d("ExpoAudioCallback", "AudioDeviceCallback ➜ ADDED (interesting): $matched")
                communicationAudioManager.onDeviceChanged()
                pipelineIntegration.logAudioTrackHealth("device_added")
                val params = Bundle()
                params.putString("reason", "newDeviceAvailable")
                sendExpoEvent(Constants.DEVICE_RECONNECTED_EVENT_NAME, params)
            }
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            val descriptions = removedDevices?.map { "${it.productName} (type=${it.type})" } ?: emptyList()
            Log.d("ExpoAudioCallback", "onAudioDevicesRemoved: $descriptions")

            val lastOfGroup = removedDevices?.filter { d ->
                d.type in interestingTypes && reportedGroups.remove(groupKey(d.type))
            }
            if (lastOfGroup?.isNotEmpty() == true) {
                val matched = lastOfGroup.map { "${it.productName} (type=${it.type})" }
                Log.d("ExpoAudioCallback", "AudioDeviceCallback ➜ REMOVED (interesting): $matched")
                communicationAudioManager.onDeviceChanged()
                pipelineIntegration.logAudioTrackHealth("device_removed")
                val params = Bundle()
                params.putString("reason", "oldDeviceUnavailable")
                sendExpoEvent(Constants.DEVICE_RECONNECTED_EVENT_NAME, params)
            }
        }
    }

    @SuppressLint("MissingPermission")
    @RequiresApi(Build.VERSION_CODES.R)
    override fun definition() = ModuleDefinition {
        Name("ExpoPlayAudioStream")

        Events(
            Constants.AUDIO_EVENT_NAME,
            Constants.MICROPHONE_ERROR_EVENT_NAME,
            Constants.DEVICE_RECONNECTED_EVENT_NAME,
            PipelineIntegration.EVENT_STATE_CHANGED,
            PipelineIntegration.EVENT_PLAYBACK_STARTED,
            PipelineIntegration.EVENT_ERROR,
            PipelineIntegration.EVENT_ZOMBIE_DETECTED,
            PipelineIntegration.EVENT_UNDERRUN,
            PipelineIntegration.EVENT_DRAINED,
            PipelineIntegration.EVENT_PLAYBACK_STOPPED,
            PipelineIntegration.EVENT_AUDIO_FOCUS_LOST,
            PipelineIntegration.EVENT_AUDIO_FOCUS_RESUMED,
            PipelineIntegration.EVENT_FREQUENCY_BANDS
        )

        // Initialize managers
        initializeManager()
        initializePipeline()

        OnCreate {
            audioManager = appContext.reactContext?.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            communicationAudioManager = CommunicationAudioManager(audioManager)
            audioManager.registerAudioDeviceCallback(audioCallCallback, mainHandler)
        }

        OnDestroy {
            reportedGroups.clear()
            audioManager.unregisterAudioDeviceCallback(audioCallCallback)
            pipelineIntegration.destroy()
            audioRecorderManager.release()
            communicationAudioManager.forceReset(appContext.currentActivity)
        }

        AsyncFunction("destroy") { promise: Promise ->
            pipelineIntegration.destroy()
            audioRecorderManager.release()
            communicationAudioManager.forceReset(appContext.currentActivity)

            // Reinitialize all managers so the module can be used again
            initializeManager()
            initializePipeline()
            communicationAudioManager = CommunicationAudioManager(audioManager)
            promise.resolve(null)
        }

        AsyncFunction("requestPermissionsAsync") { promise: Promise ->
            Permissions.askForPermissionsWithPermissionsManager(
                appContext.permissions,
                promise,
                Manifest.permission.RECORD_AUDIO
            )
        }

        AsyncFunction("getPermissionsAsync") { promise: Promise ->
            Permissions.getPermissionsWithPermissionsManager(
                appContext.permissions,
                promise,
                Manifest.permission.RECORD_AUDIO
            )
        }

        AsyncFunction("startMicrophone") { options: Map<String, Any?>, promise: Promise ->
            communicationAudioManager.startSession(appContext.currentActivity)
            audioRecorderManager.startRecording(options, promise)
        }

        AsyncFunction("stopMicrophone") { promise: Promise ->
            audioRecorderManager.stopRecording(promise)
            communicationAudioManager.stopSession(appContext.currentActivity)
        }

        Function("toggleSilence") { isSilent: Boolean ->
            audioRecorderManager.toggleSilence(isSilent)
        }

        Function("setMicrophoneGain") { gain: Double ->
            audioRecorderManager.setMicrophoneGain(gain.toFloat())
        }

        // ── Native Audio Pipeline V3 ────────────────────────────────────

        AsyncFunction("connectPipeline") { options: Map<String, Any?>, promise: Promise ->
            communicationAudioManager.startSession(appContext.currentActivity)
            pipelineIntegration.connect(options, promise)
        }

        AsyncFunction("pushPipelineAudio") { options: Map<String, Any?>, promise: Promise ->
            pipelineIntegration.pushAudio(options, promise)
        }

        Function("pushPipelineAudioSync") { options: Map<String, Any?> ->
            pipelineIntegration.pushAudioSync(options)
        }

        AsyncFunction("disconnectPipeline") { promise: Promise ->
            pipelineIntegration.disconnect(promise)
            communicationAudioManager.stopSession(appContext.currentActivity)
        }

        AsyncFunction("invalidatePipelineTurn") { options: Map<String, Any?>, promise: Promise ->
            pipelineIntegration.invalidateTurn(options, promise)
        }

        Function("getPipelineTelemetry") {
            pipelineIntegration.getTelemetry()
        }

        Function("getPipelineState") {
            pipelineIntegration.getState()
        }

        Function("getPipelineOutputLatencyMs") {
            pipelineIntegration.outputLatencyMs()
        }

    }
    private fun initializeManager() {
        val androidContext =
            appContext.reactContext ?: throw IllegalStateException("Android context not available")
        val permissionUtils = PermissionUtils(androidContext)
        val audioEncoder = AudioDataEncoder()
        val audioEffectsManager = AudioEffectsManager()
        audioRecorderManager =
            AudioRecorderManager(
                permissionUtils,
                audioEncoder,
                this,
                audioEffectsManager
            )
    }

    private fun initializePipeline() {
        val ctx = appContext.reactContext
            ?: throw IllegalStateException("Android context not available")
        pipelineIntegration = PipelineIntegration(ctx, this)
    }

    override fun sendExpoEvent(eventName: String, params: Bundle) {
        Log.d(Constants.TAG, "Sending event EXPO: $eventName")
        this@ExpoPlayAudioStreamModule.sendEvent(eventName, params)
    }
}

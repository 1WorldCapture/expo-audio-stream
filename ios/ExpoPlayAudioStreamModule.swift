import Foundation
import AVFoundation
import ExpoModulesCore

let audioDataEvent: String = "AudioData"
let microphoneErrorEvent: String = "MicrophoneError"
let deviceReconnectedEvent: String = "DeviceReconnected"


public class ExpoPlayAudioStreamModule: Module, MicrophoneDataDelegate, PipelineEventSender {
    private var _microphone: Microphone?
    private var _pipelineIntegration: PipelineIntegration?

    /// Single shared AVAudioEngine used by AudioPipeline.
    private let sharedAudioEngine = SharedAudioEngine()

    private var microphone: Microphone {
        if _microphone == nil {
            _microphone = Microphone()
            _microphone?.delegate = self
            _microphone?.sharedAudioEngine = sharedAudioEngine
        }
        return _microphone!
    }

    private var pipelineIntegration: PipelineIntegration {
        if _pipelineIntegration == nil {
            _pipelineIntegration = PipelineIntegration(eventSender: self, sharedEngine: sharedAudioEngine)
        }
        return _pipelineIntegration!
    }

    private var isAudioSessionInitialized: Bool = false

    // ── PipelineEventSender conformance ───────────────────────────────
    func sendPipelineEvent(_ eventName: String, _ params: [String: Any]) {
        sendEvent(eventName, params)
    }

    public func definition() -> ModuleDefinition {
        Name("ExpoPlayAudioStream")

        // Defines event names that the module can send to JavaScript.
        Events([
            audioDataEvent,
            microphoneErrorEvent,
            deviceReconnectedEvent,
            PipelineIntegration.EVENT_STATE_CHANGED,
            PipelineIntegration.EVENT_PLAYBACK_STARTED,
            PipelineIntegration.EVENT_ERROR,
            PipelineIntegration.EVENT_ZOMBIE_DETECTED,
            PipelineIntegration.EVENT_UNDERRUN,
            PipelineIntegration.EVENT_DRAINED,
            PipelineIntegration.EVENT_PLAYBACK_STOPPED,
            PipelineIntegration.EVENT_AUDIO_FOCUS_LOST,
            PipelineIntegration.EVENT_AUDIO_FOCUS_RESUMED,
            PipelineIntegration.EVENT_FREQUENCY_BANDS,
        ])

        AsyncFunction("destroy") { (promise: Promise) in
            // Stop the microphone before tearing down the engine so the tap is
            // cleanly removed and the capture callback cannot fire on a dead node.
            self._microphone?.stopRecording(resolver: nil)
            self._pipelineIntegration?.destroy()
            self._pipelineIntegration = nil
            self.sharedAudioEngine.teardown()
            if self.isAudioSessionInitialized {
                let audioSession = AVAudioSession.sharedInstance()
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                self.isAudioSessionInitialized = false
            }
            self._microphone = nil
            promise.resolve(nil)
        }

        /// Prompts the user to select the microphone mode.
        Function("promptMicrophoneModes") {
            promptForMicrophoneModes()
        }

        /// Requests microphone permission from the user.
        AsyncFunction("requestPermissionsAsync") { (promise: Promise) in
            checkMicrophonePermission { granted in
                promise.resolve([
                    "granted": granted,
                    "canAskAgain": true,
                    "status": granted ? "granted" : "denied"
                ])
            }
        }

        /// Gets the current microphone permission status.
        AsyncFunction("getPermissionsAsync") { (promise: Promise) in
            let status = AVAudioSession.sharedInstance().recordPermission
            let granted = status == .granted
            let canAskAgain = status == .undetermined
            promise.resolve([
                "granted": granted,
                "canAskAgain": canAskAgain,
                "status": granted ? "granted" : (canAskAgain ? "undetermined" : "denied")
            ])
        }

        AsyncFunction("startMicrophone") { (options: [String: Any], promise: Promise) in
            // Create recording settings
            // Extract settings from provided options, using default values if necessary
            let sampleRate = options["sampleRate"] as? Double ?? 16000.0
            let numberOfChannels = options["channelConfig"] as? Int ?? 1
            let bitDepth = options["audioFormat"] as? Int ?? 16
            let interval = options["interval"] as? Int ?? 1000

            let fbConfigDict = options["frequencyBandConfig"] as? [String: Any]
            let fbConfig: (lowCrossoverHz: Float, highCrossoverHz: Float)? = fbConfigDict.map {
                (
                    lowCrossoverHz: ($0["lowCrossoverHz"] as? NSNumber)?.floatValue ?? 300,
                    highCrossoverHz: ($0["highCrossoverHz"] as? NSNumber)?.floatValue ?? 2000
                )
            }

            let settings = RecordingSettings(
                sampleRate: sampleRate,
                desiredSampleRate: sampleRate,
                numberOfChannels: numberOfChannels,
                bitDepth: bitDepth,
                maxRecentDataDuration: nil,
                pointsPerSecond: nil
            )

            do {
                if !isAudioSessionInitialized {
                    try ensureAudioSessionInitialized(settings: settings)
                }
                // Ensure the shared engine is configured so AEC is applied to mic audio.
                if !self.sharedAudioEngine.isConfigured {
                    try self.sharedAudioEngine.configure(playbackMode: .conversation)
                }
            } catch {
                promise.reject("ERROR", "Failed to init audio session: \(error.localizedDescription)")
                return
            }

            if let result = self.microphone.startRecording(settings: settings, intervalMilliseconds: interval, frequencyBandConfig: fbConfig) {
                if let resError = result.error {
                    promise.reject("ERROR", resError)
                } else {
                    let resultDict: [String: Any] = [
                        "fileUri": result.fileUri ?? "",
                        "channels": result.channels ?? 1,
                        "bitDepth": result.bitDepth ?? 16,
                        "sampleRate": result.sampleRate ?? 48000,
                        "mimeType": result.mimeType ?? "",
                    ]
                    promise.resolve(resultDict)
                }
            } else {
                promise.reject("ERROR", "Failed to start recording.")
            }
        }

        AsyncFunction("stopMicrophone") { (promise: Promise) in
            microphone.stopRecording(resolver: promise)
        }

        Function("toggleSilence") { (isSilent: Bool) in
            microphone.toggleSilence(isSilent: isSilent)
        }

        Function("setMicrophoneGain") { (gain: Double) in
            microphone.setMicrophoneGain(Float(gain))
        }

        // ── Pipeline functions ────────────────────────────────────────────

        AsyncFunction("connectPipeline") { (options: [String: Any], promise: Promise) in
            do {
                // Always ensure the session is set up (no-op if already initialized).
                // The one-time guard inside ensureAudioSessionInitialized covers
                // the mic-only path; we re-apply the category below every connect
                // because audioMode may change between connects.
                if !self.isAudioSessionInitialized {
                    try self.ensureAudioSessionInitialized()
                }

                // Parse audioMode (default: "mixWithOthers")
                let audioModeString = options["audioMode"] as? String ?? "mixWithOthers"
                var categoryOptions: AVAudioSession.CategoryOptions =
                    [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
                switch audioModeString {
                case "mixWithOthers":
                    categoryOptions.insert(.mixWithOthers)
                case "duckOthers":
                    categoryOptions.insert(.duckOthers)
                case "doNotMix":
                    break  // no additional option
                default:
                    categoryOptions.insert(.mixWithOthers)
                }

                // Reconfigure the session category with the right mix options.
                // Runtime category changes are supported on iOS.
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(
                    .playAndRecord, mode: .videoChat, options: categoryOptions)
                try audioSession.setActive(true)

                // Parse playback mode from options to configure shared engine.
                // Always use VP — this library is meant for mic+speaker combos.
                let playbackModeString = options["playbackMode"] as? String ?? "conversation"
                let playbackMode: PlaybackMode
                switch playbackModeString {
                case "voiceProcessing":
                    playbackMode = .voiceProcessing
                default:
                    playbackMode = .conversation
                }

                // Configure shared engine (handles voice processing)
                try self.sharedAudioEngine.configure(playbackMode: playbackMode)

                let result = try self.pipelineIntegration.connect(options: options)

                // Set the AudioPipeline as the active delegate for route/interruption callbacks
                self.pipelineIntegration.setAsActiveDelegate(on: self.sharedAudioEngine)

                promise.resolve(result)
            } catch {
                // Reset session + engine state so a subsequent connect can recover.
                // Without this, a partial failure (e.g. setActive denial after the
                // iOS local-network permission prompt) leaves the session stuck and
                // every retry fails the same way.
                self._pipelineIntegration?.removeAsDelegate(from: self.sharedAudioEngine)
                self._pipelineIntegration?.disconnect()
                self.sharedAudioEngine.teardown()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.isAudioSessionInitialized = false
                promise.reject("PIPELINE_CONNECT_ERROR", error.localizedDescription)
            }
        }

        AsyncFunction("pushPipelineAudio") { (options: [String: Any], promise: Promise) in
            do {
                try self.pipelineIntegration.pushAudio(options: options)
                promise.resolve(nil)
            } catch {
                promise.reject("PIPELINE_PUSH_ERROR", error.localizedDescription)
            }
        }

        Function("pushPipelineAudioSync") { (options: [String: Any]) -> Bool in
            return self.pipelineIntegration.pushAudioSync(options: options)
        }

        AsyncFunction("disconnectPipeline") { (promise: Promise) in
            self.pipelineIntegration.removeAsDelegate(from: self.sharedAudioEngine)
            self.pipelineIntegration.disconnect()
            promise.resolve(nil)
        }

        AsyncFunction("invalidatePipelineTurn") { (options: [String: Any], promise: Promise) in
            do {
                try self.pipelineIntegration.invalidateTurn(options: options)
                promise.resolve(nil)
            } catch {
                promise.reject("PIPELINE_INVALIDATE_ERROR", error.localizedDescription)
            }
        }

        Function("getPipelineTelemetry") { () -> [String: Any] in
            return self.pipelineIntegration.getTelemetry()
        }

        Function("getPipelineState") { () -> String in
            return self.pipelineIntegration.getState()
        }

        Function("getPipelineOutputLatencyMs") { () -> Double in
            return self.pipelineIntegration.outputLatencyMs()
        }
    }

    private func ensureAudioSessionInitialized(settings recordingSettings: RecordingSettings? = nil) throws {
        if self.isAudioSessionInitialized { return }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord, mode: .videoChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        if let settings = recordingSettings {
            try audioSession.setPreferredSampleRate(settings.sampleRate)
            let hwSampleRate = audioSession.sampleRate > 0 ? audioSession.sampleRate : 48000.0
            let preferredDuration = 512.0 / hwSampleRate
            try audioSession.setPreferredIOBufferDuration(preferredDuration)
        }
        try audioSession.setActive(true)
        isAudioSessionInitialized = true
     }

    // used for voice isolation, experimental
    private func promptForMicrophoneModes() {
        guard #available(iOS 15.0, *) else {
            return
        }

        if AVCaptureDevice.preferredMicrophoneMode == .voiceIsolation {
            return
        }

        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// Checks microphone permission and calls the completion handler with the result.
    private func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }

    func onMicrophoneData(_ microphoneData: Data, _ soundLevel: Float?, _ frequencyBands: FrequencyBands?) {
        let encodedData = microphoneData.base64EncodedString()
        var eventBody: [String: Any] = [
            "fileUri": "",
            "lastEmittedSize": 0,
            "position": 0,
            "encoded": encodedData,
            "deltaSize": 0,
            "totalSize": 0,
            "mimeType": "",
            "soundLevel": soundLevel ?? -160
        ]
        if let bands = frequencyBands {
            eventBody["frequencyBands"] = [
                "low": bands.low,
                "mid": bands.mid,
                "high": bands.high
            ]
        }
        sendEvent(audioDataEvent, eventBody)
    }

    func onMicrophoneError(_ error: MicrophoneErrorInfo) {
        // Rich structured channel for new consumers
        sendEvent(microphoneErrorEvent, [
            "code": error.code,
            "message": error.message,
            "isFatal": error.isFatal,
            "autoResuming": error.autoResuming,
        ])
        // Backward-compat: keep the error variant on AudioData for existing consumers
        sendEvent(audioDataEvent, [
            "error": error.code,
            "errorMessage": error.message,
            "streamUuid": "",
        ])
    }

    func onDeviceReconnected(_ reason: AVAudioSession.RouteChangeReason) {
        let reasonString: String
        switch reason {
        case .newDeviceAvailable:
            reasonString = "newDeviceAvailable"
        case .oldDeviceUnavailable:
            reasonString = "oldDeviceUnavailable"
        case .unknown, .categoryChange, .override, .wakeFromSleep, .noSuitableRouteForCategory, .routeConfigurationChange:
            reasonString = "unknown"
        @unknown default:
            reasonString = "unknown"
        }

        sendEvent(deviceReconnectedEvent, ["reason": reasonString])
    }
}

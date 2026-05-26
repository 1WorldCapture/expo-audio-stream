import AVFoundation
import ExpoModulesCore


class Microphone {
    weak var delegate: MicrophoneDataDelegate?
    
    private var audioEngine: AVAudioEngine!
    private var audioConverter: AVAudioConverter!
    private var inputNode: AVAudioInputNode!
    
    public private(set) var isVoiceProcessingEnabled: Bool = false
    
    
    internal var lastEmittedSize: Int64 = 0
    private var totalDataSize: Int64 = 0
    internal var recordingSettings: RecordingSettings?

    internal var mimeType: String = "audio/wav"
    private var lastBufferTime: AVAudioTime?
    
    private var startTime: Date?
    private var pauseStartTime: Date?
    

    private var inittedAudioSession = false
    private var isRecording: Bool = false
    private var isSilent: Bool = false
    private var frequencyBandAnalyzer: FrequencyBandAnalyzer?
    private var frequencyBandConfig: (lowCrossoverHz: Float, highCrossoverHz: Float)?

    /// Interval (in ms) the consumer last requested. Used to rebuild the tap
    /// with the same cadence when resuming after an interruption.
    private var lastIntervalMs: Int = 100
    /// Set when an audio session interruption begins while recording is active.
    /// Cleared either by `stopRecording` (consumer chose disconnect) or by the
    /// `.ended` handler after a successful auto-resume.
    private var pendingInterruptionResume: Bool = false
    
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Handles audio route changes (e.g. headphones connected/disconnected)
    /// - Parameter notification: The notification object containing route change information
    @objc private func handleRouteChange(notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        Logger.debug("[Microphone] Route is changed \(reason)")

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            if isRecording {
                stopRecording(resolver: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, let settings = self.recordingSettings else { return }

                    let result = self.startRecording(
                        settings: settings,
                        intervalMilliseconds: self.lastIntervalMs,
                        frequencyBandConfig: self.frequencyBandConfig
                    )
                    if let error = result?.error {
                        // Silent failure here would leave the consumer's UI
                        // showing "recording" while the native engine is dead.
                        // Surface a terminal error matching the interruption
                        // resume path's RESUME_FAILED.
                        self.delegate?.onMicrophoneError(
                            "RESTART_FAILED",
                            "Could not restart microphone after route change: \(error)"
                        )
                    }
                }
            }
        case .categoryChange:
            Logger.debug("[Microphone] Audio Session category changed")
        default:
            break
        }
    }

    /// Handles audio session interruptions (e.g. Siri, phone call, alarm).
    ///
    /// On `.began` we stop the engine (iOS deactivates the session regardless)
    /// but keep `isRecording = true` and emit an `INTERRUPTED` error so the
    /// consumer can decide:
    ///   - Call `stopRecording` to disconnect explicitly (clears the resume flag).
    ///   - Do nothing to let the library auto-resume when the system gives the
    ///     mic back on `.ended`.
    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            Logger.debug("[Microphone] Audio session interruption began")
            guard isRecording else { return }
            // Tear down the engine but leave isRecording true so the consumer's
            // intent is preserved. The .ended branch will decide whether to
            // resume based on whether stopRecording was called in between.
            pendingInterruptionResume = true
            if let engine = audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            delegate?.onMicrophoneError("INTERRUPTED", "Audio session interrupted by system")
        case .ended:
            Logger.debug("[Microphone] Audio session interruption ended")
            guard pendingInterruptionResume else { return }
            pendingInterruptionResume = false
            // iOS uses AVAudioSessionInterruptionOptionKey.shouldResume to hint
            // whether the app can safely reactivate. Absent means another app
            // took over (e.g. an ongoing call) — in that case we surface a
            // terminal error instead of attempting a doomed restart.
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard options.contains(.shouldResume) else {
                Logger.debug("[Microphone] System did not signal shouldResume — treating as terminal stop")
                isRecording = false
                delegate?.onMicrophoneError(
                    "RESUME_DENIED",
                    "System did not permit microphone resume after interruption"
                )
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try installTapAndStartEngine(intervalMilliseconds: lastIntervalMs)
                Logger.debug("[Microphone] Auto-resumed after interruption")
            } catch {
                Logger.debug("[Microphone] Auto-resume failed: \(error.localizedDescription)")
                // Engine couldn't restart — surface as terminal stop.
                isRecording = false
                delegate?.onMicrophoneError(
                    "RESUME_FAILED",
                    "Could not restart microphone after interruption: \(error.localizedDescription)"
                )
            }
        @unknown default:
            break
        }
    }

    /// Installs the audio tap on the input node and starts the engine.
    /// Shared between fresh `startRecording` and post-interruption resume.
    private func installTapAndStartEngine(intervalMilliseconds: Int) throws {
        let hardwareFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        let intervalSamples = AVAudioFrameCount(
            Double(intervalMilliseconds) / 1000.0 * hardwareFormat.sampleRate
        )
        let tapBufferSize = max(intervalSamples, 256)

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { [weak self] (buffer, time) in
            guard let self = self else { return }

            guard buffer.frameLength > 0 else {
                Logger.debug("Error: received empty buffer in tap callback")
                self.delegate?.onMicrophoneError("READ_ERROR", "Received empty audio buffer")
                return
            }

            self.processAudioBuffer(buffer)
            self.lastBufferTime = time
        }

        try audioEngine.start()
    }
    
    func toggleSilence(isSilent: Bool) {
        Logger.debug("[Microphone] toggleSilence")
        self.isSilent = isSilent
    }
    
    func startRecording(settings: RecordingSettings, intervalMilliseconds: Int,
                        frequencyBandConfig: (lowCrossoverHz: Float, highCrossoverHz: Float)? = nil) -> StartRecordingResult? {
        guard !isRecording else {
            Logger.debug("Debug: Recording is already in progress.")
            return StartRecordingResult(error: "Recording is already in progress.")
        }
        
        if self.audioEngine == nil {
            self.audioEngine = AVAudioEngine()
        }
        
        if self.audioEngine != nil && audioEngine.isRunning  {
            Logger.debug("Debug: Audio engine already running.")
            audioEngine.stop()
        }
       
        var newSettings = settings  // Make settings mutable

        totalDataSize = 0
        
        // Use the hardware's native format for the tap to avoid Core Audio format mismatch crashes.
        // The inputNode delivers audio in the hardware format (e.g. 48kHz Float32).
        // Resampling and format conversion to the desired settings happens in processAudioBuffer.
        let hardwareFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        newSettings.sampleRate = hardwareFormat.sampleRate
        Logger.debug("Debug: Hardware sample rate is \(hardwareFormat.sampleRate) Hz, desired sample rate is \(settings.sampleRate) Hz")

        recordingSettings = newSettings  // Update the class property with the new settings

        self.frequencyBandConfig = frequencyBandConfig
        self.lastIntervalMs = intervalMilliseconds
        // Analyzer uses the desired (target) sample rate, not hardware rate
        let targetRate = Int(settings.desiredSampleRate ?? settings.sampleRate)
        let fbConfig = frequencyBandConfig ?? (lowCrossoverHz: Float(300), highCrossoverHz: Float(2000))
        frequencyBandAnalyzer = FrequencyBandAnalyzer(
            sampleRate: targetRate,
            lowCrossoverHz: fbConfig.lowCrossoverHz,
            highCrossoverHz: fbConfig.highCrossoverHz
        )

        do {
            startTime = Date()
            try installTapAndStartEngine(intervalMilliseconds: intervalMilliseconds)
            isRecording = true
            Logger.debug("Debug: Recording started successfully.")
            return StartRecordingResult(
                fileUri: "",
                mimeType: mimeType,
                channels: settings.numberOfChannels,
                bitDepth: settings.bitDepth,
                sampleRate: settings.sampleRate
            )
        } catch {
            Logger.debug("Error: Could not start the audio engine: \(error.localizedDescription)")
            isRecording = false
            return StartRecordingResult(error: "Error: Could not start the audio engine: \(error.localizedDescription)")
        }
    }
    
    public func stopRecording(resolver promise: Promise?) {
        // Clear resume intent up-front so a stopRecording call during an
        // active interruption window cancels the auto-resume on .ended.
        pendingInterruptionResume = false
        guard self.isRecording else {
            if let promiseResolver = promise {
                promiseResolver.resolve(nil)
            }
            return
        }
        self.isRecording = false
        self.isVoiceProcessingEnabled = false
       
        // Remove tap before stopping the engine
        if audioEngine != nil {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            frequencyBandAnalyzer = nil
        }

        if let promiseResolver = promise {
            promiseResolver.resolve(nil)
        }
    }
    
    /// Processes the audio buffer and writes data to the file. Also handles audio processing if enabled.
    /// - Parameters:
    ///   - buffer: The audio buffer to process.
    ///   - fileURL: The URL of the file to write the data to.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let targetSampleRate = recordingSettings?.desiredSampleRate ?? buffer.format.sampleRate
        let targetBitDepth = recordingSettings?.bitDepth ?? 16
        var currentBuffer = buffer

        // Resample if needed
        if currentBuffer.format.sampleRate != targetSampleRate {
            if let resampledBuffer = AudioUtils.resampleAudioBuffer(currentBuffer, from: currentBuffer.format.sampleRate, to: targetSampleRate) {
                currentBuffer = resampledBuffer
            } else if let convertedBuffer = AudioUtils.tryConvertToFormat(
                inputBuffer: currentBuffer,
                desiredSampleRate: targetSampleRate,
                desiredChannel: 1,
                bitDepth: targetBitDepth
            ) {
                currentBuffer = convertedBuffer
            } else {
                Logger.debug("Failed to resample audio buffer.")
            }
        }

        let powerLevel: Float = self.isSilent ? -160.0 : AudioUtils.calculatePowerLevel(from: currentBuffer)

        // Convert Float32 → Int16 PCM if needed (the tap delivers hardware-native Float32)
        let data: Data
        if isSilent {
            let byteCount = Int(currentBuffer.frameCapacity) * Int(currentBuffer.format.streamDescription.pointee.mBytesPerFrame)
            data = Data(repeating: 0, count: byteCount)
        } else if targetBitDepth == 16 && currentBuffer.format.commonFormat == .pcmFormatFloat32,
                  let floatData = currentBuffer.floatChannelData {
            let frameCount = Int(currentBuffer.frameLength)
            let channelCount = Int(currentBuffer.format.channelCount)
            var int16Data = Data(capacity: frameCount * channelCount * 2)
            for frame in 0..<frameCount {
                for ch in 0..<channelCount {
                    let sample = max(-1.0, min(1.0, floatData[ch][frame]))
                    var int16Sample = Int16(sample * 32767.0)
                    int16Data.append(Data(bytes: &int16Sample, count: 2))
                }
            }
            data = int16Data
        } else {
            let audioData = currentBuffer.audioBufferList.pointee.mBuffers
            guard let bufferData = audioData.mData else {
                Logger.debug("Buffer data is nil.")
                return
            }
            data = Data(bytes: bufferData, count: Int(audioData.mDataByteSize))
        }

        // Compute frequency bands from the Int16 PCM data
        let bands: FrequencyBands?
        if isSilent {
            bands = .zero
        } else if let analyzer = frequencyBandAnalyzer {
            analyzer.processSamplesFromData(data)
            bands = analyzer.harvest()
        } else {
            bands = nil
        }

        totalDataSize += Int64(data.count)

        // Emit immediately — tap buffer size is already interval-aligned
        self.delegate?.onMicrophoneData(data, powerLevel, bands)
        self.lastEmittedSize = totalDataSize
    }
}

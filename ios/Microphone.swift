import AVFoundation
import ExpoModulesCore


class Microphone: SharedAudioEngineDelegate {
    weak var delegate: MicrophoneDataDelegate?

    /// The shared engine whose VP-enabled input node this microphone taps.
    /// Must be set and configured before calling startRecording.
    weak var sharedAudioEngine: SharedAudioEngine?

    /// Serial queue for mic-input processing. The tap fires on AVFoundation's
    /// real-time render thread; we copy the buffer and hop here so resampling,
    /// frequency analysis and the JS `sendEvent` never run on that thread (a
    /// real-time violation that can stall capture or invert priority). Kept
    /// separate from the engine queue so a congested JS bridge on the mic path
    /// can't stall playback scheduling.
    private let micQueue = DispatchQueue(label: "expo.modules.audio.microphone")

    public private(set) var isVoiceProcessingEnabled: Bool = false

    internal var lastEmittedSize: Int64 = 0
    private var totalDataSize: Int64 = 0
    internal var recordingSettings: RecordingSettings?

    internal var mimeType: String = "audio/wav"
    private var lastBufferTime: AVAudioTime?

    private var startTime: Date?

    private var isRecording: Bool = false
    private var isSilent: Bool = false
    // Read on the audio render thread, written from the JS thread.
    // Float is 4 bytes / naturally aligned — atomic on ARM64, no lock needed.
    private var micGain: Float = 1.0
    private var frequencyBandAnalyzer: FrequencyBandAnalyzer?
    private var frequencyBandConfig: (lowCrossoverHz: Float, highCrossoverHz: Float)?

    private var lastIntervalMs: Int = 100
    private var pendingInterruptionResume: Bool = false

    // ── SharedAudioEngineDelegate ────────────────────────────────────────

    func engineDidRestartAfterRouteChange() {
        guard isRecording else { return }
        // Engine restarted in-place; tap was removed on stop — reinstall.
        do {
            try installTap(intervalMilliseconds: lastIntervalMs)
        } catch {
            Logger.debug("[Microphone] Failed to reinstall tap after route change: \(error)")
            failRecording(MicrophoneErrorInfo(
                code: "RESTART_FAILED",
                message: "Could not reinstall microphone tap after route change: \(error.localizedDescription)",
                isFatal: true,
                autoResuming: false
            ))
        }
    }

    func engineDidRebuild() {
        guard isRecording else { return }
        // New AVAudioEngine instance — installTap picks up the new inputNode automatically.
        do {
            try installTap(intervalMilliseconds: lastIntervalMs)
        } catch {
            Logger.debug("[Microphone] Failed to reinstall tap after engine rebuild: \(error)")
            failRecording(MicrophoneErrorInfo(
                code: "RESTART_FAILED",
                message: "Could not reinstall microphone tap after engine rebuild: \(error.localizedDescription)",
                isFatal: true,
                autoResuming: false
            ))
        }
    }

    func audioSessionResumeDenied() {
        guard isRecording else { return }
        failRecording(MicrophoneErrorInfo(
            code: "RESUME_DENIED",
            message: "System did not permit microphone resume after interruption",
            isFatal: true,
            autoResuming: false
        ))
    }

    func audioSessionInterruptionBegan() {
        guard isRecording else { return }
        pendingInterruptionResume = true
        delegate?.onMicrophoneError(MicrophoneErrorInfo(
            code: "INTERRUPTED",
            message: "Audio session interrupted by system",
            isFatal: false,
            autoResuming: true
        ))
    }

    func audioSessionInterruptionEnded() {
        guard pendingInterruptionResume else { return }
        pendingInterruptionResume = false
        do {
            try installTap(intervalMilliseconds: lastIntervalMs)
        } catch {
            Logger.debug("[Microphone] Failed to reinstall tap after interruption resume: \(error)")
            failRecording(MicrophoneErrorInfo(
                code: "RESUME_FAILED",
                message: "Could not reinstall microphone tap after interruption: \(error.localizedDescription)",
                isFatal: true,
                autoResuming: false
            ))
        }
    }

    func engineDidDie(reason: String) {
        guard isRecording else { return }
        failRecording(MicrophoneErrorInfo(
            code: "ENGINE_DIED",
            message: reason,
            isFatal: true,
            autoResuming: false
        ))
    }

    // ── Core recording API ───────────────────────────────────────────────

    func toggleSilence(isSilent: Bool) {
        Logger.debug("[Microphone] toggleSilence")
        self.isSilent = isSilent
    }

    func setMicrophoneGain(_ gain: Float) {
        micGain = max(0.0, min(1.0, gain))
    }

    func startRecording(settings: RecordingSettings, intervalMilliseconds: Int,
                        frequencyBandConfig: (lowCrossoverHz: Float, highCrossoverHz: Float)? = nil) -> StartRecordingResult? {
        guard !isRecording else {
            Logger.debug("[Microphone] Recording is already in progress.")
            return StartRecordingResult(error: "Recording is already in progress.")
        }
        guard let shared = sharedAudioEngine, shared.isConfigured, let engine = shared.engine else {
            Logger.debug("[Microphone] Shared audio engine is not configured.")
            return StartRecordingResult(error: "Shared audio engine is not configured.")
        }

        var newSettings = settings
        totalDataSize = 0

        let hardwareFormat = engine.inputNode.inputFormat(forBus: 0)
        newSettings.sampleRate = hardwareFormat.sampleRate
        Logger.debug("[Microphone] Hardware sample rate: \(hardwareFormat.sampleRate) Hz, desired: \(settings.sampleRate) Hz")

        recordingSettings = newSettings
        self.frequencyBandConfig = frequencyBandConfig
        self.lastIntervalMs = intervalMilliseconds

        let targetRate = Int(settings.desiredSampleRate ?? settings.sampleRate)
        let fbConfig = frequencyBandConfig ?? (lowCrossoverHz: Float(300), highCrossoverHz: Float(2000))
        frequencyBandAnalyzer = FrequencyBandAnalyzer(
            sampleRate: targetRate,
            lowCrossoverHz: fbConfig.lowCrossoverHz,
            highCrossoverHz: fbConfig.highCrossoverHz
        )

        sharedAudioEngine?.addDelegate(self)
        do {
            startTime = Date()
            try installTap(intervalMilliseconds: intervalMilliseconds)
            isRecording = true
            Logger.debug("[Microphone] Recording started successfully.")
            return StartRecordingResult(
                fileUri: "",
                mimeType: mimeType,
                channels: settings.numberOfChannels,
                bitDepth: settings.bitDepth,
                sampleRate: settings.sampleRate
            )
        } catch {
            Logger.debug("[Microphone] Could not start recording: \(error.localizedDescription)")
            sharedAudioEngine?.removeDelegate(self)
            isRecording = false
            return StartRecordingResult(error: "Could not start recording: \(error.localizedDescription)")
        }
    }

    public func stopRecording(resolver promise: Promise?) {
        pendingInterruptionResume = false
        guard isRecording else {
            promise?.resolve(nil)
            return
        }
        isRecording = false
        isVoiceProcessingEnabled = false
        sharedAudioEngine?.engine?.inputNode.removeTap(onBus: 0)
        sharedAudioEngine?.removeDelegate(self)
        frequencyBandAnalyzer = nil
        promise?.resolve(nil)
    }

    // ── Private helpers ──────────────────────────────────────────────────

    private func failRecording(_ error: MicrophoneErrorInfo) {
        isRecording = false
        pendingInterruptionResume = false
        sharedAudioEngine?.engine?.inputNode.removeTap(onBus: 0)
        sharedAudioEngine?.removeDelegate(self)
        frequencyBandAnalyzer = nil
        delegate?.onMicrophoneError(error)
    }

    private func installTap(intervalMilliseconds: Int) throws {
        guard let inputNode = sharedAudioEngine?.engine?.inputNode else {
            throw NSError(domain: "Microphone", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Shared engine input node unavailable"])
        }

        // Remove any stale tap before installing — AVAudioEngine crashes if a tap
        // is already present on the bus. Engine restarts do not guarantee tap removal.
        inputNode.removeTap(onBus: 0)

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        recordingSettings?.sampleRate = hardwareFormat.sampleRate

        // outputFormat is what the tap actually receives — under VoiceProcessingIO
        // this may differ from inputFormat (VP may output at a different rate and
        // adds internal metadata channels beyond channel 0).
        let nodeOutputFormat = inputNode.outputFormat(forBus: 0)

        let intervalSamples = AVAudioFrameCount(
            Double(intervalMilliseconds) / 1000.0 * nodeOutputFormat.sampleRate
        )
        let tapBufferSize = max(intervalSamples, 256)

        // Explicit mono Float32 format strips VP metadata channels. Passing format: nil
        // here would deliver the raw VP output channels, corrupting the audio stream
        // with echo-tracking metadata that bleeds into downstream processing.
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nodeOutputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: tapFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            guard buffer.frameLength > 0 else {
                Logger.debug("[Microphone] Received empty buffer in tap callback")
                self.micQueue.async {
                    self.delegate?.onMicrophoneError(MicrophoneErrorInfo(
                        code: "READ_ERROR",
                        message: "Received empty audio buffer",
                        isFatal: false,
                        autoResuming: false
                    ))
                }
                return
            }
            // Convert on the render thread — the tap buffer is only valid here, and
            // the conversion yields the `Data` we'd build anyway, so there's no
            // extra copy. Hand the value-typed result to the serial queue; only the
            // JS-bridge delivery (sendEvent) runs off the render thread. Nothing
            // here re-enters the engine, so no separate queue is needed for safety —
            // micQueue exists purely to keep the bridge call off the render thread
            // and preserve chunk ordering.
            guard let payload = self.extractMicData(from: buffer) else { return }
            self.micQueue.async {
                self.totalDataSize += Int64(payload.data.count)
                self.delegate?.onMicrophoneData(payload.data, payload.powerLevel, payload.bands)
                self.lastEmittedSize = self.totalDataSize
                self.lastBufferTime = time
            }
        }
    }

    /// Convert a tap buffer into the value-typed payload the delegate needs
    /// (PCM `Data`, power level, frequency bands). Runs on the audio render
    /// thread — it needs the live buffer — but does no cross-thread work, so the
    /// caller hands the result to `micQueue` for the JS-bridge delivery. Returns
    /// nil if the buffer yields no data.
    private func extractMicData(from buffer: AVAudioPCMBuffer) -> (data: Data, powerLevel: Float, bands: FrequencyBands?)? {
        let targetSampleRate = recordingSettings?.desiredSampleRate ?? buffer.format.sampleRate
        let targetBitDepth = recordingSettings?.bitDepth ?? 16
        var currentBuffer = buffer

        if currentBuffer.format.sampleRate != targetSampleRate {
            if let resampledBuffer = AudioUtils.resampleAudioBuffer(
                currentBuffer, from: currentBuffer.format.sampleRate, to: targetSampleRate) {
                currentBuffer = resampledBuffer
            } else if let convertedBuffer = AudioUtils.tryConvertToFormat(
                inputBuffer: currentBuffer,
                desiredSampleRate: targetSampleRate,
                desiredChannel: 1,
                bitDepth: targetBitDepth
            ) {
                currentBuffer = convertedBuffer
            } else {
                Logger.debug("[Microphone] Failed to resample audio buffer.")
            }
        }

        let powerLevel: Float = self.isSilent ? -160.0 : AudioUtils.calculatePowerLevel(from: currentBuffer)

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
                    let sample = max(-1.0, min(1.0, floatData[ch][frame] * micGain))
                    var int16Sample = Int16(sample * 32767.0)
                    int16Data.append(Data(bytes: &int16Sample, count: 2))
                }
            }
            data = int16Data
        } else {
            let audioData = currentBuffer.audioBufferList.pointee.mBuffers
            guard let bufferData = audioData.mData else {
                Logger.debug("[Microphone] Buffer data is nil.")
                return nil
            }
            data = Data(bytes: bufferData, count: Int(audioData.mDataByteSize))
        }

        let bands: FrequencyBands?
        if isSilent {
            bands = .zero
        } else if let analyzer = frequencyBandAnalyzer {
            analyzer.processSamplesFromData(data)
            bands = analyzer.harvest()
        } else {
            bands = nil
        }

        return (data, powerLevel, bands)
    }
}

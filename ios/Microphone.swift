import AVFoundation
import ExpoModulesCore


class Microphone: SharedAudioEngineDelegate {
    weak var delegate: MicrophoneDataDelegate?

    /// The shared engine whose VP-enabled input node this microphone taps.
    /// Must be set and configured before calling startRecording.
    weak var sharedAudioEngine: SharedAudioEngine?

    public private(set) var isVoiceProcessingEnabled: Bool = false

    internal var lastEmittedSize: Int64 = 0
    private var totalDataSize: Int64 = 0
    internal var recordingSettings: RecordingSettings?

    internal var mimeType: String = "audio/wav"
    private var lastBufferTime: AVAudioTime?

    private var startTime: Date?

    private var isRecording: Bool = false
    private var isSilent: Bool = false
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
            isRecording = false
            sharedAudioEngine?.removeDelegate(self)
            frequencyBandAnalyzer = nil
            delegate?.onMicrophoneError(MicrophoneErrorInfo(
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
            isRecording = false
            sharedAudioEngine?.removeDelegate(self)
            frequencyBandAnalyzer = nil
            delegate?.onMicrophoneError(MicrophoneErrorInfo(
                code: "RESTART_FAILED",
                message: "Could not reinstall microphone tap after engine rebuild: \(error.localizedDescription)",
                isFatal: true,
                autoResuming: false
            ))
        }
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
            isRecording = false
            sharedAudioEngine?.removeDelegate(self)
            frequencyBandAnalyzer = nil
            delegate?.onMicrophoneError(MicrophoneErrorInfo(
                code: "RESUME_FAILED",
                message: "Could not reinstall microphone tap after interruption: \(error.localizedDescription)",
                isFatal: true,
                autoResuming: false
            ))
        }
    }

    func engineDidDie(reason: String) {
        guard isRecording else { return }
        isRecording = false
        sharedAudioEngine?.removeDelegate(self)
        frequencyBandAnalyzer = nil
        delegate?.onMicrophoneError(MicrophoneErrorInfo(
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

    func startRecording(settings: RecordingSettings, intervalMilliseconds: Int,
                        frequencyBandConfig: (lowCrossoverHz: Float, highCrossoverHz: Float)? = nil) -> StartRecordingResult? {
        guard !isRecording else {
            Logger.debug("[Microphone] Recording is already in progress.")
            return StartRecordingResult(error: "Recording is already in progress.")
        }
        guard let shared = sharedAudioEngine, shared.isConfigured, shared.engine != nil else {
            Logger.debug("[Microphone] Shared audio engine is not configured.")
            return StartRecordingResult(error: "Shared audio engine is not configured.")
        }

        var newSettings = settings
        totalDataSize = 0

        let hardwareFormat = shared.engine!.inputNode.inputFormat(forBus: 0)
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

        do {
            startTime = Date()
            try installTap(intervalMilliseconds: intervalMilliseconds)
            sharedAudioEngine?.addDelegate(self)
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

        let intervalSamples = AVAudioFrameCount(
            Double(intervalMilliseconds) / 1000.0 * hardwareFormat.sampleRate
        )
        let tapBufferSize = max(intervalSamples, 256)

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { [weak self] (buffer, time) in
            guard let self = self else { return }
            guard buffer.frameLength > 0 else {
                Logger.debug("[Microphone] Received empty buffer in tap callback")
                self.delegate?.onMicrophoneError(MicrophoneErrorInfo(
                    code: "READ_ERROR",
                    message: "Received empty audio buffer",
                    isFatal: false,
                    autoResuming: false
                ))
                return
            }
            self.processAudioBuffer(buffer)
            self.lastBufferTime = time
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
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
                    let sample = max(-1.0, min(1.0, floatData[ch][frame]))
                    var int16Sample = Int16(sample * 32767.0)
                    int16Data.append(Data(bytes: &int16Sample, count: 2))
                }
            }
            data = int16Data
        } else {
            let audioData = currentBuffer.audioBufferList.pointee.mBuffers
            guard let bufferData = audioData.mData else {
                Logger.debug("[Microphone] Buffer data is nil.")
                return
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

        totalDataSize += Int64(data.count)
        self.delegate?.onMicrophoneData(data, powerLevel, bands)
        self.lastEmittedSize = totalDataSize
    }
}

import Foundation

/// Protocol for sending pipeline events to the Expo module (analogous to Android's EventSender).
protocol PipelineEventSender: AnyObject {
    func sendPipelineEvent(_ eventName: String, _ params: [String: Any])
}

/// Bridge layer wiring AudioPipeline into ExpoPlayAudioStreamModule.
///
/// Holds the pipeline instance, implements PipelineListener to forward native events
/// as Expo bridge events, and exposes the 7 bridge methods that the module's
/// definition() block declares.
class PipelineIntegration: PipelineListener {
    private static let TAG = "PipelineIntegration"

    // ── Event name constants (match the TS PipelineEventMap keys) ─────
    static let EVENT_STATE_CHANGED       = "PipelineStateChanged"
    static let EVENT_PLAYBACK_STARTED    = "PipelinePlaybackStarted"
    static let EVENT_ERROR               = "PipelineError"
    static let EVENT_ZOMBIE_DETECTED     = "PipelineZombieDetected"
    static let EVENT_UNDERRUN            = "PipelineUnderrun"
    static let EVENT_DRAINED             = "PipelineDrained"
    static let EVENT_PLAYBACK_STOPPED    = "PipelinePlaybackStopped"
    static let EVENT_AUDIO_FOCUS_LOST    = "PipelineAudioFocusLost"
    static let EVENT_AUDIO_FOCUS_RESUMED = "PipelineAudioFocusResumed"
    static let EVENT_FREQUENCY_BANDS    = "PipelineFrequencyBands"

    private weak var eventSender: PipelineEventSender?
    private weak var sharedEngine: SharedAudioEngine?
    private var pipeline: AudioPipeline?

    init(eventSender: PipelineEventSender, sharedEngine: SharedAudioEngine) {
        self.eventSender = eventSender
        self.sharedEngine = sharedEngine
    }

    // ════════════════════════════════════════════════════════════════════
    // Bridge methods
    // ════════════════════════════════════════════════════════════════════

    /// Connect the pipeline. Creates a new AudioPipeline with the given options.
    ///
    /// Options:
    ///   - `sampleRate` (Int, default 24000)
    ///   - `channelCount` (Int, default 1)
    ///   - `targetBufferMs` (Int, default 80)
    ///
    /// Returns a dictionary with the resolved config on success.
    func connect(options: [String: Any]) throws -> [String: Any] {
        // Tear down any existing pipeline first
        pipeline?.disconnect()

        guard let sharedEngine = sharedEngine else {
            throw NSError(domain: "PipelineIntegration", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SharedAudioEngine not set"])
        }

        let sampleRate = (options["sampleRate"] as? NSNumber)?.intValue ?? 24000
        let channelCount = (options["channelCount"] as? NSNumber)?.intValue ?? 1
        let targetBufferMs = (options["targetBufferMs"] as? NSNumber)?.intValue ?? 80
        let frequencyBandIntervalMs = (options["frequencyBandIntervalMs"] as? NSNumber)?.intValue ?? 100
        let bandConfig = options["frequencyBandConfig"] as? [String: Any]
        let lowCrossoverHz = (bandConfig?["lowCrossoverHz"] as? NSNumber)?.floatValue ?? 300
        let highCrossoverHz = (bandConfig?["highCrossoverHz"] as? NSNumber)?.floatValue ?? 2000

        let p = AudioPipeline(
            sampleRate: sampleRate,
            channelCount: channelCount,
            targetBufferMs: targetBufferMs,
            frequencyBandIntervalMs: frequencyBandIntervalMs,
            lowCrossoverHz: lowCrossoverHz,
            highCrossoverHz: highCrossoverHz,
            sharedEngine: sharedEngine,
            listener: self
        )
        try p.connect()
        pipeline = p

        return [
            "sampleRate": sampleRate,
            "channelCount": channelCount,
            "targetBufferMs": targetBufferMs,
            "frameSizeSamples": p.frameSizeSamples
        ]
    }

    /// Push base64-encoded PCM audio into the jitter buffer (async path).
    ///
    /// Options:
    ///   - `audio` (String) — base64-encoded PCM16 LE data
    ///   - `turnId` (String) — conversation turn identifier
    ///   - `isFirstChunk` (Boolean, default false)
    ///   - `isLastChunk` (Boolean, default false)
    func pushAudio(options: [String: Any]) throws {
        guard let audio = options["audio"] as? String else {
            throw NSError(domain: "PipelineIntegration", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing 'audio' field"])
        }
        guard let turnId = options["turnId"] as? String else {
            throw NSError(domain: "PipelineIntegration", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing 'turnId' field"])
        }
        let isFirstChunk = options["isFirstChunk"] as? Bool ?? false
        let isLastChunk = options["isLastChunk"] as? Bool ?? false

        guard let p = pipeline else {
            throw NSError(domain: "PipelineIntegration", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Pipeline not connected"])
        }
        p.pushAudio(base64Audio: audio, turnId: turnId, isFirstChunk: isFirstChunk, isLastChunk: isLastChunk)
    }

    /// Push base64-encoded PCM audio synchronously (no Promise overhead).
    /// Returns true on success, false on failure.
    func pushAudioSync(options: [String: Any]) -> Bool {
        guard let audio = options["audio"] as? String,
              let turnId = options["turnId"] as? String else {
            return false
        }
        let isFirstChunk = options["isFirstChunk"] as? Bool ?? false
        let isLastChunk = options["isLastChunk"] as? Bool ?? false

        guard let p = pipeline else { return false }
        p.pushAudio(base64Audio: audio, turnId: turnId, isFirstChunk: isFirstChunk, isLastChunk: isLastChunk)
        return true
    }

    /// Disconnect the pipeline. Tears down AVAudioEngine, timers, etc.
    func disconnect() {
        pipeline?.disconnect()
        pipeline = nil
    }

    /// Invalidate the current turn — discards stale audio in the jitter buffer.
    ///
    /// Options:
    ///   - `turnId` (String) — the new turn identifier
    func invalidateTurn(options: [String: Any]) throws {
        guard let turnId = options["turnId"] as? String else {
            throw NSError(domain: "PipelineIntegration", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing 'turnId' field"])
        }
        pipeline?.invalidateTurn(newTurnId: turnId)
    }

    /// Get current pipeline telemetry as a dictionary (returned to JS as a map).
    func getTelemetry() -> [String: Any] {
        return pipeline?.getTelemetry() ?? ["state": PipelineState.idle.rawValue]
    }

    /// Get current pipeline state string.
    func getState() -> String {
        return pipeline?.getState().rawValue ?? PipelineState.idle.rawValue
    }

    /// Current platform output latency in milliseconds. Returns 0 if not connected.
    func outputLatencyMs() -> Double {
        return pipeline?.outputLatencyMs() ?? 0
    }

    /// Register the pipeline as a delegate on the shared engine.
    /// Called by the module after connect() so route changes and interruptions
    /// are forwarded to the AudioPipeline instance.
    func setAsActiveDelegate(on engine: SharedAudioEngine) {
        if let p = pipeline {
            engine.addDelegate(p)
        }
    }

    /// Remove the pipeline delegate from the shared engine.
    /// Called by the module before disconnect so stale callbacks aren't delivered.
    func removeAsDelegate(from engine: SharedAudioEngine) {
        if let p = pipeline {
            engine.removeDelegate(p)
        }
    }

    /// Destroy the integration — called from module destroy().
    func destroy() {
        if let p = pipeline, let engine = sharedEngine {
            engine.removeDelegate(p)
        }
        pipeline?.disconnect()
        pipeline = nil
    }

    // ════════════════════════════════════════════════════════════════════
    // PipelineListener implementation → Expo bridge events
    // ════════════════════════════════════════════════════════════════════

    func onStateChanged(_ state: PipelineState) {
        sendEvent(PipelineIntegration.EVENT_STATE_CHANGED, ["state": state.rawValue])
    }

    func onPlaybackStarted(turnId: String) {
        sendEvent(PipelineIntegration.EVENT_PLAYBACK_STARTED, ["turnId": turnId])
    }

    func onError(code: String, message: String) {
        sendEvent(PipelineIntegration.EVENT_ERROR, ["code": code, "message": message])
    }

    func onZombieDetected(stalledMs: Int64) {
        sendEvent(PipelineIntegration.EVENT_ZOMBIE_DETECTED, ["stalledMs": stalledMs])
    }

    func onUnderrun(count: Int) {
        sendEvent(PipelineIntegration.EVENT_UNDERRUN, ["count": count])
    }

    func onDrained(turnId: String) {
        sendEvent(PipelineIntegration.EVENT_DRAINED, ["turnId": turnId])
    }

    func onPlaybackStopped(turnId: String) {
        sendEvent(PipelineIntegration.EVENT_PLAYBACK_STOPPED, ["turnId": turnId])
    }

    func onAudioFocusLost() {
        sendEvent(PipelineIntegration.EVENT_AUDIO_FOCUS_LOST, [:])
    }

    func onAudioFocusResumed() {
        sendEvent(PipelineIntegration.EVENT_AUDIO_FOCUS_RESUMED, [:])
    }

    func onFrequencyBands(low: Float, mid: Float, high: Float) {
        sendEvent(PipelineIntegration.EVENT_FREQUENCY_BANDS, [
            "low": low, "mid": mid, "high": high
        ])
    }

    // ── Helper ────────────────────────────────────────────────────────

    private func sendEvent(_ eventName: String, _ params: [String: Any]) {
        eventSender?.sendPipelineEvent(eventName, params)
    }
}

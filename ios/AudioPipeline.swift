import AVFoundation

/// Pipeline states reported to JS via PipelineListener.onStateChanged.
enum PipelineState: String {
    case idle = "idle"
    case connecting = "connecting"
    case streaming = "streaming"
    case draining = "draining"
    case error = "error"
}

/// Listener interface — implemented by PipelineIntegration to bridge events to JS.
protocol PipelineListener: AnyObject {
    func onStateChanged(_ state: PipelineState)
    func onPlaybackStarted(turnId: String)
    func onError(code: String, message: String)
    func onZombieDetected(stalledMs: Int64)
    func onUnderrun(count: Int)
    func onDrained(turnId: String)
    func onPlaybackStopped(turnId: String)
    func onAudioFocusLost()
    func onAudioFocusResumed()
    func onFrequencyBands(low: Float, mid: Float, high: Float)
}

/// Core orchestrator for the native audio pipeline (iOS).
///
/// Attaches an AVAudioPlayerNode to the SharedAudioEngine, feeds it from a
/// JitterBuffer via a scheduling loop that chains buffer completions for
/// continuous output.
///
/// Key design points:
///   - The player node stays alive for the entire session, playing silence when
///     idle (via JitterBuffer returning zeros when not primed).
///   - Config is immutable per session — disconnect and reconnect to change
///     sample rate.
///   - Route changes and interruptions are handled by SharedAudioEngine;
///     this class implements SharedAudioEngineDelegate for re-seeding.
///   - Zombie detection via timer checking that the scheduling loop is active.
///   - Turn management synchronized via turnLock to prevent interleaved
///     buffer.reset + buffer.write.
class AudioPipeline: SharedAudioEngineDelegate {
    private static let TAG = "AudioPipeline"

    /// Number of buffers to pre-schedule for continuous output.
    private static let PRE_SCHEDULE_COUNT = 3

    /// How often (seconds) the state-monitoring timer fires.
    private static let STATE_POLL_INTERVAL: TimeInterval = 0.05

    /// How often (seconds) zombie detection checks.
    private static let ZOMBIE_POLL_INTERVAL: TimeInterval = 2.0

    /// If scheduling loop hasn't run for this long, declare zombie.
    private static let ZOMBIE_STALL_THRESHOLD_MS: Int64 = 5000

    // ── Config (immutable per session) ──────────────────────────────────
    private let sampleRate: Int
    private let channelCount: Int
    private let targetBufferMs: Int
    private let frequencyBandIntervalMs: Int
    private let lowCrossoverHz: Float
    private let highCrossoverHz: Float
    private weak var listener: PipelineListener?
    private weak var sharedEngine: SharedAudioEngine?

    // ── Core components ─────────────────────────────────────────────────
    private var playerNode: AVAudioPlayerNode?
    private var outputFormat: AVAudioFormat?
    private var jitterBuffer: JitterBuffer?

    /// Number of interleaved Int16 samples read from the JitterBuffer per scheduled buffer
    /// (at pipeline sample rate, e.g. 16 kHz).
    let frameSizeSamples: Int

    /// Hardware output sample rate — read at connect time from the engine's output node.
    /// The player node connects at this rate so AVAudioEngine injects no hidden resampler,
    /// keeping the AEC echo reference deterministically timed.
    private var hardwareSampleRate: Double = 48000

    /// Number of frames written to the hardware-rate PCM buffer per scheduled buffer.
    /// Always >= frameSizeSamples; computed as hardwareSampleRate / 50 (20 ms chunks).
    private var hwFramesPerBuffer: Int = 960

    // ── Threading / state ───────────────────────────────────────────────
    private var running = false
    private let turnLock = NSLock()
    private var currentTurnId: String?
    private var playbackStartedForTurn = false
    private var lastReportedUnderrunCount = 0
    private var isInterrupted = false

    /// Incremented each time the scheduling loop is torn down (route change, disconnect).
    /// Completion handlers capture the generation at scheduling time and bail if it's stale.
    /// This prevents duplicate chains and stale callbacks from re-entering after a rebuild.
    private var scheduleGeneration: Int = 0

    /// All `node.scheduleBuffer(...)` calls for this pipeline run on the shared
    /// engine's serial `engineQueue` (the same queue that owns stop/detach/attach),
    /// so `scheduleBuffer()` and teardown's `stop()` can never overlap — that
    /// overlap is the AVAudioPlayerNode deadlock (AttachAndEngineLock ⇄
    /// RealtimeMessenger). The buffer-completion callback re-arms via
    /// `engineQueue.async` (returns immediately so `stop()`'s message flush isn't
    /// blocked); teardown runs on the same queue via `sharedEngine.performSync`,
    /// so it's serialized after any in-flight scheduling with no explicit barrier.

    /// Pending PlaybackStopped dispatch — cancelled on new turn / disconnect.
    /// Always mutate from the main queue to avoid races with the drain timer.
    private var pendingPlaybackStoppedWork: DispatchWorkItem?

    // ── Timers ──────────────────────────────────────────────────────────
    private var stateTimer: DispatchSourceTimer?
    private var zombieTimer: DispatchSourceTimer?
    private var frequencyBandTimer: DispatchSourceTimer?
    private var frequencyBandAnalyzer: FrequencyBandAnalyzer?
    private var lastEmittedBands: FrequencyBands?
    private var lastScheduleTime = Date()

    // ── Pipeline state ──────────────────────────────────────────────────
    private var state: PipelineState = .idle

    // ── Telemetry ───────────────────────────────────────────────────────
    private(set) var totalPushCalls: Int64 = 0
    private(set) var totalPushBytes: Int64 = 0
    private(set) var totalScheduledBuffers: Int64 = 0

    // ── Pre-allocated render buffer ─────────────────────────────────────
    private var renderSamples: [Int16] = []

    init(sampleRate: Int, channelCount: Int, targetBufferMs: Int,
         frequencyBandIntervalMs: Int = 100,
         lowCrossoverHz: Float = 300, highCrossoverHz: Float = 2000,
         sharedEngine: SharedAudioEngine, listener: PipelineListener) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.targetBufferMs = targetBufferMs
        self.frequencyBandIntervalMs = frequencyBandIntervalMs
        self.lowCrossoverHz = lowCrossoverHz
        self.highCrossoverHz = highCrossoverHz
        self.sharedEngine = sharedEngine
        self.listener = listener
        self.frameSizeSamples = max(1, sampleRate * channelCount / 50)
    }

    // ════════════════════════════════════════════════════════════════════
    // Connect / Disconnect
    // ════════════════════════════════════════════════════════════════════

    func connect() throws {
        guard !running else {
            Logger.debug("[\(AudioPipeline.TAG)] connect() called while already running — ignoring")
            return
        }
        setState(.connecting)

        guard let sharedEngine = sharedEngine else {
            setState(.error)
            throw NSError(domain: "AudioPipeline", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SharedAudioEngine not set"])
        }

        do {
            // All graph setup runs on the engine's serial queue so attach / play /
            // seed are serialized against route-change, scheduleBuffer and teardown.
            try sharedEngine.performSync { try self.connectOnQueue(sharedEngine: sharedEngine) }
        } catch {
            Logger.debug("[\(AudioPipeline.TAG)] connect() failed: \(error)")
            setState(.error)
            disconnect()
            throw error
        }
    }

    /// Graph setup for `connect()`. Runs entirely on `sharedEngine.engineQueue`.
    private func connectOnQueue(sharedEngine: SharedAudioEngine) throws {
            // ── 1. JitterBuffer ─────────────────────────────────────────
            jitterBuffer = JitterBuffer(
                sampleRate: sampleRate,
                channels: channelCount,
                targetBufferMs: targetBufferMs
            )

            // ── 2. Pre-allocate render buffer ───────────────────────────
            renderSamples = [Int16](repeating: 0, count: frameSizeSamples)

            // ── 3. Audio session ────────────────────────────────────────
            // Session category/mode is owned by ExpoPlayAudioStreamModule
            // (ensureAudioSessionInitialized). Just ensure it's active.
            try AVAudioSession.sharedInstance().setActive(true)

            // ── 4. Read hardware rate and create hardware-rate format ───
            // Connecting at the native hardware rate prevents AVAudioEngine from
            // injecting a hidden resampler between the player node and the hardware
            // output. A hidden resampler shifts buffer timestamps and desynchronises
            // the AEC echo reference, causing the adaptive filter to converge slowly
            // or not at all. The scheduling loop handles the 16kHz→48kHz conversion
            // via linear interpolation before handing buffers to the player node.
            let rawHwRate = sharedEngine.engine?.outputNode.outputFormat(forBus: 0).sampleRate ?? 0
            let resolvedHwRate = rawHwRate > 0 ? rawHwRate : 48000
            hardwareSampleRate = resolvedHwRate
            hwFramesPerBuffer = max(1, Int(resolvedHwRate / 50.0))

            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: resolvedHwRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else {
                throw NSError(domain: "AudioPipeline", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
            }

            let node = AVAudioPlayerNode()
            sharedEngine.attachNode(node, format: format)
            node.play()

            self.playerNode = node
            self.outputFormat = format
            self.running = true

            // ── 5. Start scheduling loop ────────────────────────────────
            Logger.debug("[\(AudioPipeline.TAG)] Seeding scheduling loop — gen=\(scheduleGeneration) count=\(AudioPipeline.PRE_SCHEDULE_COUNT)")
            for _ in 0..<AudioPipeline.PRE_SCHEDULE_COUNT {
                scheduleNextBuffer()
            }

            // ── 6. State polling + zombie detection ─────────────────────
            startStatePolling()
            startZombieDetection()

            // ── 7. Reset telemetry ──────────────────────────────────────
            resetTelemetry()

            // ── 8. Frequency band analyzer ───────────────────────────────
            frequencyBandAnalyzer = FrequencyBandAnalyzer(
                sampleRate: sampleRate,
                lowCrossoverHz: lowCrossoverHz,
                highCrossoverHz: highCrossoverHz
            )
            startFrequencyBandTimer()

            setState(.idle)
            Logger.debug("[\(AudioPipeline.TAG)] Connected — pipelineRate=\(sampleRate) " +
                "hwRate=\(Int(resolvedHwRate)) ch=\(channelCount) " +
                "pipelineFrames=\(frameSizeSamples) hwFrames=\(hwFramesPerBuffer) " +
                "targetBuffer=\(targetBufferMs)ms")
    }

    func disconnect() {
        // Run teardown on the engine's serial queue so it's serialized after any
        // in-flight scheduleBuffer pass and against route-change/interruption —
        // no explicit barrier needed. If the shared engine is already gone
        // (module destroyed), just clean up local state.
        if let sharedEngine = sharedEngine {
            sharedEngine.performSync { self.disconnectOnQueue() }
        } else {
            disconnectOnQueue()
        }
    }

    /// Teardown body. Runs on `sharedEngine.engineQueue` (via `performSync`), so
    /// `running = false` and `detachNode`'s `stop()` are ordered after any
    /// scheduling pass; a buffer completion that fires during `stop()` only
    /// re-enqueues onto the same queue and then bails on `running == false`.
    private func disconnectOnQueue() {
        // Cancel any pending PlaybackStopped before tearing down.
        pendingPlaybackStoppedWork?.cancel()
        pendingPlaybackStoppedWork = nil

        running = false
        // Invalidate all in-flight completion handlers before detaching.
        scheduleGeneration += 1

        // Stop timers
        stateTimer?.cancel()
        stateTimer = nil
        zombieTimer?.cancel()
        zombieTimer = nil
        frequencyBandTimer?.cancel()
        frequencyBandTimer = nil
        frequencyBandAnalyzer = nil
        lastEmittedBands = nil

        // Detach node from shared engine (handles pause/stop/disconnect/detach).
        // detachNode is performSync → runs inline since we're already on the queue.
        if let node = playerNode {
            sharedEngine?.detachNode(node)
        }

        playerNode = nil
        outputFormat = nil
        jitterBuffer = nil
        currentTurnId = nil

        setState(.idle)
        Logger.debug("[\(AudioPipeline.TAG)] Disconnected")
    }

    // ════════════════════════════════════════════════════════════════════
    // SharedAudioEngineDelegate
    // ════════════════════════════════════════════════════════════════════

    func engineDidRestartAfterRouteChange() {
        guard running else {
            Logger.debug("[\(AudioPipeline.TAG)] engineDidRestartAfterRouteChange — not running, skipping")
            return
        }
        let engineRunning = sharedEngine?.engine?.isRunning == true
        let nodeExists = playerNode != nil
        // Bump generation so any in-flight completions from before the rebuild are invalidated.
        // Without this, stopped-node completions that fire after isRebuilding clears would
        // re-enter the loop alongside our re-seed, doubling the scheduling chain.
        scheduleGeneration += 1
        Logger.debug("[\(AudioPipeline.TAG)] Engine restarted after route change — " +
            "re-seeding scheduling loop (gen=\(scheduleGeneration), engineRunning=\(engineRunning), node=\(nodeExists), " +
            "state=\(state.rawValue), bufferMs=\(jitterBuffer?.bufferedMs() ?? -1))")
        // Node was already re-attached and started by SharedAudioEngine.
        // Re-seed the scheduling loop with a fresh generation.
        lastScheduleTime = Date()  // Reset zombie timer baseline
        for _ in 0..<AudioPipeline.PRE_SCHEDULE_COUNT {
            scheduleNextBuffer()
        }
    }

    func engineDidRebuild() {
        guard running else {
            Logger.debug("[\(AudioPipeline.TAG)] engineDidRebuild — not running, skipping")
            return
        }

        Logger.debug("[\(AudioPipeline.TAG)] Engine rebuilt — creating fresh node and re-seeding")

        // Old node is invalid (detached during teardown). Create a fresh one.
        scheduleGeneration += 1

        guard let sharedEngine = sharedEngine else {
            Logger.debug("[\(AudioPipeline.TAG)] engineDidRebuild — engine missing, treating as dead")
            running = false
            setState(.error)
            listener?.onError(code: "ENGINE_DIED", message: "Failed to recreate audio node after engine rebuild")
            return
        }

        // Re-read hardware rate from the new engine (route may have changed).
        let rawHwRate = sharedEngine.engine?.outputNode.outputFormat(forBus: 0).sampleRate ?? 0
        let resolvedHwRate = rawHwRate > 0 ? rawHwRate : hardwareSampleRate
        hardwareSampleRate = resolvedHwRate
        hwFramesPerBuffer = max(1, Int(resolvedHwRate / 50.0))

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: resolvedHwRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            Logger.debug("[\(AudioPipeline.TAG)] engineDidRebuild — cannot create format, treating as dead")
            running = false
            setState(.error)
            listener?.onError(code: "ENGINE_DIED", message: "Failed to recreate audio node after engine rebuild")
            return
        }

        let node = AVAudioPlayerNode()
        sharedEngine.attachNode(node, format: format)
        node.play()

        self.playerNode = node
        self.outputFormat = format

        let engineRunning = sharedEngine.engine?.isRunning == true
        let nodeExists = playerNode != nil
        Logger.debug("[\(AudioPipeline.TAG)] Fresh node attached after rebuild — " +
            "gen=\(scheduleGeneration), engineRunning=\(engineRunning), node=\(nodeExists), " +
            "state=\(state.rawValue), bufferMs=\(jitterBuffer?.bufferedMs() ?? -1))")

        // Re-seed scheduling loop
        lastScheduleTime = Date()
        for _ in 0..<AudioPipeline.PRE_SCHEDULE_COUNT {
            scheduleNextBuffer()
        }
    }

    func engineDidDie(reason: String) {
        Logger.debug("[\(AudioPipeline.TAG)] Engine died: \(reason)")
        // Stop the pipeline so all state is cleaned up.
        // Don't call disconnect() since the engine is already torn down —
        // just reset our own state.
        running = false
        scheduleGeneration += 1
        stateTimer?.cancel()
        stateTimer = nil
        zombieTimer?.cancel()
        zombieTimer = nil
        frequencyBandTimer?.cancel()
        frequencyBandTimer = nil
        frequencyBandAnalyzer = nil
        lastEmittedBands = nil
        playerNode = nil
        outputFormat = nil
        jitterBuffer = nil
        currentTurnId = nil
        setState(.error)
        listener?.onError(code: "ENGINE_DIED", message: reason)
    }

    func audioSessionInterruptionBegan() {
        Logger.debug("[\(AudioPipeline.TAG)] Audio session interruption began")
        isInterrupted = true
        listener?.onAudioFocusLost()
    }

    func audioSessionInterruptionEnded() {
        Logger.debug("[\(AudioPipeline.TAG)] Audio session interruption ended")
        isInterrupted = false
        // Reset the zombie baseline as we clear the interruption: scheduling was
        // stalled while interrupted, and the re-seed below runs asynchronously on
        // the engine queue, so without this the zombie timer could false-positive
        // in the gap before the first resumed buffer is scheduled.
        lastScheduleTime = Date()
        // Engine already restarted by SharedAudioEngine. Re-seed scheduling.
        if running {
            scheduleGeneration += 1
            for _ in 0..<AudioPipeline.PRE_SCHEDULE_COUNT {
                scheduleNextBuffer()
            }
        }
        listener?.onAudioFocusResumed()
    }

    // ════════════════════════════════════════════════════════════════════
    // Push audio (bridge thread → jitter buffer)
    // ════════════════════════════════════════════════════════════════════

    func pushAudio(base64Audio: String, turnId: String, isFirstChunk: Bool, isLastChunk: Bool) {
        guard let buf = jitterBuffer else {
            listener?.onError(code: "NOT_CONNECTED", message: "Pipeline not connected")
            return
        }

        turnLock.lock()
        defer { turnLock.unlock() }

        // ── Turn boundary handling ──────────────────────────────────────
        if isFirstChunk || currentTurnId != turnId {
            buf.reset()
            currentTurnId = turnId
            playbackStartedForTurn = false
            lastReportedUnderrunCount = 0
            setState(.streaming)
            frequencyBandAnalyzer?.reset()
            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingPlaybackStopped()
            }
        }

        // ── Decode base64 → PCM shorts ──────────────────────────────────
        guard let bytes = Data(base64Encoded: base64Audio) else {
            listener?.onError(code: "DECODE_ERROR", message: "Base64 decode failed")
            return
        }

        let sampleCount = bytes.count / 2
        var samples = [Int16](repeating: 0, count: sampleCount)
        bytes.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Int16(littleEndian: ptr[i])
            }
        }

        // ── Write into jitter buffer ────────────────────────────────────
        buf.write(samples: samples)

        // ── Telemetry ───────────────────────────────────────────────────
        totalPushCalls += 1
        totalPushBytes += Int64(bytes.count)

        // ── End-of-stream ───────────────────────────────────────────────
        if isLastChunk {
            buf.markEndOfStream()
            setState(.draining)
        }
    }

    /// Invalidate the current turn. Resets the jitter buffer so stale audio
    /// is discarded immediately.
    func invalidateTurn(newTurnId: String) {
        turnLock.lock()
        defer { turnLock.unlock() }
        jitterBuffer?.reset()
        currentTurnId = newTurnId
        playbackStartedForTurn = false
        lastReportedUnderrunCount = 0
        setState(.idle)
        frequencyBandAnalyzer?.reset()
        DispatchQueue.main.async { [weak self] in
            self?.cancelPendingPlaybackStopped()
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // State & Telemetry
    // ════════════════════════════════════════════════════════════════════

    func getState() -> PipelineState { return state }

    func getTelemetry() -> [String: Any] {
        let buf = jitterBuffer
        return [
            "state": state.rawValue,
            "bufferMs": buf?.bufferedMs() ?? 0,
            "bufferSamples": buf?.availableSamples() ?? 0,
            "primed": buf?.isPrimed() ?? false,
            "totalWritten": buf?.totalWritten ?? 0,
            "totalRead": buf?.totalRead ?? 0,
            "underrunCount": buf?.underrunCount ?? 0,
            "peakLevel": buf?.peakLevel ?? 0,
            "totalPushCalls": totalPushCalls,
            "totalPushBytes": totalPushBytes,
            "totalScheduledBuffers": totalScheduledBuffers,
            "turnId": currentTurnId ?? ""
        ]
    }

    /// Current platform output latency in milliseconds.
    ///
    /// Reads `AVAudioSession.sharedInstance().outputLatency`. The value
    /// reflects total HW output latency to the speaker and changes on
    /// audio route changes (built-in vs. Bluetooth vs. wired).
    ///
    /// Returns 0 if not running.
    func outputLatencyMs() -> Double {
        guard running else { return 0 }
        return AVAudioSession.sharedInstance().outputLatency * 1000.0
    }

    // ════════════════════════════════════════════════════════════════════
    // Scheduling loop
    // ════════════════════════════════════════════════════════════════════

    /// Request one buffer-scheduling pass. Hops onto the shared engine's serial
    /// `engineQueue` so the actual `scheduleBuffer()` is serialized against
    /// teardown's `stop()` and graph mutations. All re-seed call sites (connect,
    /// route change, rebuild, interruption) use this; the completion handler
    /// re-arms via `engineQueue.async` directly (see below).
    private func scheduleNextBuffer() {
        sharedEngine?.engineQueue.async { [weak self] in
            self?.scheduleNextBufferOnQueue()
        }
    }

    /// Build and schedule the next PCM buffer. MUST run on `engineQueue`.
    private func scheduleNextBufferOnQueue() {
        guard running,
              let se = sharedEngine, !se.isRebuilding,
              let buf = jitterBuffer,
              let node = playerNode,
              let format = outputFormat,
              se.engine?.isRunning == true else { return }

        // Capture the current generation so the completion handler can detect staleness.
        let capturedGeneration = scheduleGeneration

        // Read interleaved Int16 samples from jitter buffer
        buf.read(dest: &renderSamples, length: frameSizeSamples)

        // Analyze frequency bands on the raw Int16 samples.
        // Only feed real audio (streaming/draining) — not silence frames
        // written while idle/priming, which would dilute RMS energy.
        if !isInterrupted && (state == .streaming || state == .draining) {
            renderSamples.withUnsafeBufferPointer { bufferPtr in
                if let baseAddress = bufferPtr.baseAddress {
                    frequencyBandAnalyzer?.processSamples(baseAddress, count: frameSizeSamples)
                }
            }
        }

        // Build a hardware-rate PCM buffer. The scheduling loop resamples from
        // pipeline rate (e.g. 16 kHz) to hardware rate (e.g. 48 kHz) so the
        // player node connects at the native rate and the engine never inserts a
        // hidden resampler that would desynchronise the AEC echo reference.
        let pipelineFrames = frameSizeSamples / channelCount  // frames at pipeline rate
        let hwFrames       = hwFramesPerBuffer                 // frames at hardware rate
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(hwFrames)
        ) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(hwFrames)

        if let channelData = pcmBuffer.floatChannelData {
            if isInterrupted {
                for ch in 0..<channelCount {
                    for i in 0..<hwFrames { channelData[ch][i] = 0 }
                }
            } else {
                // Linear interpolation: pipeline rate → hardware rate
                let ratio = hardwareSampleRate / Double(sampleRate)
                for i in 0..<hwFrames {
                    let virtualIndex = Double(i) / ratio
                    let indexLow  = Int(virtualIndex)
                    let indexHigh = min(indexLow + 1, pipelineFrames - 1)
                    let weight    = Float(virtualIndex - Double(indexLow))
                    for ch in 0..<channelCount {
                        let sampleLow  = Float(renderSamples[indexLow  * channelCount + ch]) / 32768.0
                        let sampleHigh = Float(renderSamples[indexHigh * channelCount + ch]) / 32768.0
                        channelData[ch][i] = sampleLow + weight * (sampleHigh - sampleLow)
                    }
                }
            }
        }

        totalScheduledBuffers += 1
        lastScheduleTime = Date()

        node.scheduleBuffer(pcmBuffer) { [weak self] in
            guard let self = self else { return }
            // Re-arm on the engine queue. Returning from this completion callback
            // IMMEDIATELY is essential: AVAudioPlayerNode.stop() flushes pending
            // completion messages synchronously while holding the engine lock, so
            // calling scheduleBuffer() inline here would deadlock a concurrent
            // stop() (AttachAndEngineLock ⇄ RealtimeMessenger mutex). Hopping to
            // engineQueue lets stop() drain us without blocking, and serializes
            // the next scheduleBuffer() against teardown on the same queue.
            self.sharedEngine?.engineQueue.async {
                // Bail if torn down, or if this completion belongs to a previous
                // scheduling generation (route change rebuilt the engine while
                // this buffer was in flight).
                guard self.running, self.scheduleGeneration == capturedGeneration else { return }
                self.scheduleNextBufferOnQueue()
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // State polling (runs on main thread via GCD timer)
    // ════════════════════════════════════════════════════════════════════

    private func startStatePolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + AudioPipeline.STATE_POLL_INTERVAL,
            repeating: AudioPipeline.STATE_POLL_INTERVAL)
        timer.setEventHandler { [weak self] in
            self?.checkBufferState()
        }
        timer.resume()
        stateTimer = timer
    }

    private func checkBufferState() {
        guard let buf = jitterBuffer else { return }

        turnLock.lock()
        let turnId = currentTurnId
        let alreadyStarted = playbackStartedForTurn
        let lastUnderruns = lastReportedUnderrunCount
        let currentState = state
        turnLock.unlock()

        // ── Playback-started event (once per turn) ──────────────────────
        if !alreadyStarted && buf.isPrimed() && turnId != nil {
            turnLock.lock()
            playbackStartedForTurn = true
            turnLock.unlock()
            listener?.onPlaybackStarted(turnId: turnId!)
        }

        // ── Underrun debounce ───────────────────────────────────────────
        let currentUnderruns = buf.underrunCount
        if currentUnderruns > lastUnderruns {
            turnLock.lock()
            lastReportedUnderrunCount = currentUnderruns
            turnLock.unlock()
            listener?.onUnderrun(count: currentUnderruns)
        }

        // ── Drain detection ─────────────────────────────────────────────
        if buf.isDrained() && currentState == .draining {
            if let tid = turnId {
                listener?.onDrained(turnId: tid)
                schedulePlaybackStopped(turnId: tid)
            }
            setState(.idle)
        }
    }

    /// Schedule a `PlaybackStopped` event approximately `outputLatencyMs`
    /// after `Drained`. Cancels any previously pending dispatch.
    ///
    /// Approximation note: at drain detection, up to `PRE_SCHEDULE_COUNT`
    /// pre-scheduled buffers may still be in the player node's chain — but
    /// they read silence from the empty jitter buffer, so the last audible
    /// sample stops emitting roughly `outputLatency` after this point.
    private func schedulePlaybackStopped(turnId: String) {
        pendingPlaybackStoppedWork?.cancel()
        pendingPlaybackStoppedWork = nil

        let latencyMs = outputLatencyMs()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingPlaybackStoppedWork = nil
            self.listener?.onPlaybackStopped(turnId: turnId)
        }
        pendingPlaybackStoppedWork = work

        if latencyMs > 0 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Int(latencyMs.rounded())),
                execute: work
            )
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Cancel any pending PlaybackStopped dispatch. Call from turn-boundary
    /// transitions (new pushAudio, invalidateTurn) and disconnect.
    private func cancelPendingPlaybackStopped() {
        pendingPlaybackStoppedWork?.cancel()
        pendingPlaybackStoppedWork = nil
    }

    // ════════════════════════════════════════════════════════════════════
    // Zombie detection
    // ════════════════════════════════════════════════════════════════════

    private func startZombieDetection() {
        lastScheduleTime = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + AudioPipeline.ZOMBIE_POLL_INTERVAL,
            repeating: AudioPipeline.ZOMBIE_POLL_INTERVAL)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let stalledMs = Int64(Date().timeIntervalSince(self.lastScheduleTime) * 1000)
            // Don't flag a zombie while interrupted: the engine is stopped, so
            // scheduling legitimately stalls (no buffers feed) until resume. The
            // stall is expected, not a dead scheduling loop.
            if stalledMs >= AudioPipeline.ZOMBIE_STALL_THRESHOLD_MS &&
               !self.isInterrupted &&
               (self.state == .streaming || self.state == .draining) {
                Logger.debug("[\(AudioPipeline.TAG)] Zombie detected! stalledMs=\(stalledMs)")
                self.listener?.onZombieDetected(stalledMs: stalledMs)
                self.lastScheduleTime = Date()
            }
        }
        timer.resume()
        zombieTimer = timer
    }

    // ════════════════════════════════════════════════════════════════════
    // Frequency band emission
    // ════════════════════════════════════════════════════════════════════

    private func startFrequencyBandTimer() {
        let intervalSec = TimeInterval(frequencyBandIntervalMs) / 1000.0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + intervalSec, repeating: intervalSec)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.running,
                  let analyzer = self.frequencyBandAnalyzer else { return }
            let bands: FrequencyBands
            if analyzer.hasData() {
                bands = analyzer.harvest()
                self.lastEmittedBands = bands
            } else if let last = self.lastEmittedBands {
                bands = last
            } else {
                return
            }
            self.listener?.onFrequencyBands(low: bands.low, mid: bands.mid, high: bands.high)
        }
        timer.resume()
        frequencyBandTimer = timer
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ════════════════════════════════════════════════════════════════════

    private func setState(_ newState: PipelineState) {
        guard state != newState else { return }
        state = newState
        if Thread.isMainThread {
            listener?.onStateChanged(newState)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.listener?.onStateChanged(newState)
            }
        }
    }

    private func resetTelemetry() {
        totalPushCalls = 0
        totalPushBytes = 0
        totalScheduledBuffers = 0
        jitterBuffer?.resetTelemetry()
    }
}

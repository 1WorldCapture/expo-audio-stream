import AVFoundation

/// Delegate for receiving engine lifecycle events.
/// Both AudioPipeline consumers implement this
/// to handle route changes and interruptions.
protocol SharedAudioEngineDelegate: AnyObject {
    /// Called after the engine has been restarted due to a route change.
    /// Consumer's node has already been re-attached and reconnected.
    /// Consumer should restart playback (re-seed scheduling, etc.).
    func engineDidRestartAfterRouteChange()

    /// Called after the engine was fully rebuilt (fresh AVAudioEngine instance).
    /// Old nodes are invalid — consumer MUST create and attach a fresh
    /// AVAudioPlayerNode, then restart playback.
    func engineDidRebuild()

    /// Audio session was interrupted (e.g. phone call).
    func audioSessionInterruptionBegan()

    /// Audio session interruption ended. Engine has been restarted.
    /// Consumer should restart playback.
    func audioSessionInterruptionEnded()

    /// Audio session interruption ended but the system did not signal shouldResume.
    /// Recording has been stopped. Consumer should clean up and wait for the user to reconnect.
    func audioSessionResumeDenied()

    /// Engine failed to restart after exhausting all retry attempts.
    /// All state has been torn down. Consumer should report the failure
    /// to JS and clean up its own state so a fresh connect can succeed.
    func engineDidDie(reason: String)
}

extension SharedAudioEngineDelegate {
    func audioSessionResumeDenied() {}
}

/// Owns the single AVAudioEngine shared between AudioPipeline consumers.
///
/// Responsibilities:
///   - Engine lifecycle (create, start, stop, teardown)
///   - Voice processing enable/disable based on PlaybackMode
///   - Route change handling (rebuild node connections transparently)
///   - Interruption handling (restart engine, notify delegate)
///
/// Consumers attach their own AVAudioPlayerNode via `attachNode(_:format:)`.
/// The mixer handles sample-rate conversion from each node's format to the
/// hardware output format automatically.
class SharedAudioEngine {
    private static let TAG = "SharedAudioEngine"

    /// The single serial queue that owns ALL engine graph work: every
    /// attach/detach/connect/stop/start/configure/teardown, the playback
    /// `scheduleBuffer` loop (driven from AudioPipeline), and route/interruption
    /// handling. Serial ordering here is what makes the AVAudioPlayerNode
    /// `stop()`/`scheduleBuffer()` deadlock structurally impossible — they can't
    /// overlap on one serial queue. AVFoundation callbacks hop on via `async`
    /// (never `sync` — they may run with an AV lock held); Expo functions enter
    /// via `performSync`. Replaces the former recursive lock.
    let engineQueue = DispatchQueue(label: "expo.modules.audio.engine")
    private static let queueKey = DispatchSpecificKey<Void>()

    init() {
        engineQueue.setSpecific(key: SharedAudioEngine.queueKey, value: ())
    }

    /// Run `work` synchronously in the engine's serial domain. Re-entrancy-aware:
    /// if we're already on `engineQueue` (a delegate callback fired from
    /// `notifyDelegates`, or `configure` calling `teardown`/`attachNode`) we run
    /// inline instead of dead-locking on `engineQueue.sync`. This is exactly what
    /// the *recursive* lock used to provide. Callers on AVFoundation callback
    /// threads must use `engineQueue.async` instead — never this.
    func performSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: SharedAudioEngine.queueKey) != nil {
            return try work()
        }
        return try engineQueue.sync(execute: work)
    }

    // ── Engine state ─────────────────────────────────────────────────────
    private(set) var engine: AVAudioEngine?
    private(set) var playbackMode: PlaybackMode = .conversation
    private(set) var isConfigured = false

    /// All registered consumers receive route-change and interruption callbacks.
    /// Uses NSHashTable with weak references so delegates are auto-zeroed on dealloc.
    private let delegates = NSHashTable<AnyObject>.weakObjects()

    func addDelegate(_ d: SharedAudioEngineDelegate) {
        performSync {
            if !delegates.contains(d as AnyObject) {
                delegates.add(d as AnyObject)
            }
        }
    }

    func removeDelegate(_ d: SharedAudioEngineDelegate) {
        performSync {
            delegates.remove(d as AnyObject)
        }
    }

    private func notifyDelegates(_ block: (SharedAudioEngineDelegate) -> Void) {
        for obj in delegates.allObjects {
            if let d = obj as? SharedAudioEngineDelegate {
                block(d)
            }
        }
    }

    // ── Attached nodes (for route-change rebuild) ────────────────────────
    private struct AttachedNodeInfo {
        let node: AVAudioPlayerNode
        let format: AVAudioFormat
    }
    private var attachedNodes: [AttachedNodeInfo] = []

    // ════════════════════════════════════════════════════════════════════
    // Configure
    // ════════════════════════════════════════════════════════════════════

    /// Configure (or reconfigure) the shared engine.
    ///
    /// If already configured with the same playbackMode, this is a no-op.
    /// Otherwise tears down the existing engine and creates a fresh one.
    ///
    /// - Parameter playbackMode: Determines whether voice processing is enabled.
    func configure(playbackMode: PlaybackMode) throws {
        try performSync { try configureOnQueue(playbackMode: playbackMode) }
    }

    private func configureOnQueue(playbackMode: PlaybackMode) throws {
        let needsVP = playbackMode == .conversation || playbackMode == .voiceProcessing
        let vpActive = !needsVP || (engine?.inputNode.isVoiceProcessingEnabled == true)
        if isConfigured && self.playbackMode == playbackMode && engine?.isRunning == true && vpActive {
            Logger.debug("[\(SharedAudioEngine.TAG)] Already configured for \(playbackMode) and engine running, skipping")
            return
        }
        if isConfigured && !vpActive {
            Logger.debug("[\(SharedAudioEngine.TAG)] Voice processing dropped (setCategory side-effect) — forcing reconfiguration")
        }

        if isConfigured && engine?.isRunning != true {
            Logger.debug("[\(SharedAudioEngine.TAG)] Engine marked configured but not running — forcing reconfiguration")
        }

        // Tear down existing engine (keeps attachedNodes info for re-attach)
        let previousNodes = attachedNodes
        teardown()

        Logger.debug("[\(SharedAudioEngine.TAG)] Configuring engine — playbackMode=\(playbackMode)")

        let engine = AVAudioEngine()

        // Enable voice processing for conversation / voiceProcessing modes.
        // Done before connecting nodes so the audio graph incorporates VP from the start.
        if playbackMode == .conversation || playbackMode == .voiceProcessing {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            Logger.debug("[\(SharedAudioEngine.TAG)] Voice processing enabled")
        }

        // VP accesses inputNode/outputNode above, which creates the graph.
        // Do NOT access mainMixerNode here — inserting the mixer after
        // setVoiceProcessingEnabled disrupts VoiceProcessingIO's internal
        // graph and causes scheduleBuffer completions to never fire.

        try engine.start()

        self.engine = engine
        self.playbackMode = playbackMode
        self.isConfigured = true

        // Register for notifications
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)

        // Re-attach any nodes that were connected before reconfiguration
        for info in previousNodes {
            attachNode(info.node, format: info.format)
            info.node.play()
        }

        Logger.debug("[\(SharedAudioEngine.TAG)] Engine started")
    }

    // ════════════════════════════════════════════════════════════════════
    // Node management
    // ════════════════════════════════════════════════════════════════════

    /// Whether the engine is mid-rebuild (route change). Consumers should
    /// bail out of completion handlers instead of re-scheduling.
    var isRebuilding: Bool { return isRebuildingForRouteChange }

    /// Attach a consumer's player node to the shared engine.
    ///
    /// Connects `node → mainMixerNode` with the given format.
    /// The mixer handles sample-rate conversion to hardware output.
    func attachNode(_ node: AVAudioPlayerNode, format: AVAudioFormat) {
        performSync { attachNodeOnQueue(node, format: format) }
    }

    private func attachNodeOnQueue(_ node: AVAudioPlayerNode, format: AVAudioFormat) {
        guard let engine = engine else {
            Logger.debug("[\(SharedAudioEngine.TAG)] attachNode called but engine is nil")
            return
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        attachedNodes.append(AttachedNodeInfo(node: node, format: format))

        Logger.debug("[\(SharedAudioEngine.TAG)] Node attached — format=\(format)")
    }

    /// Detach a consumer's player node from the shared engine.
    func detachNode(_ node: AVAudioPlayerNode) {
        performSync { detachNodeOnQueue(node) }
    }

    private func detachNodeOnQueue(_ node: AVAudioPlayerNode) {
        guard let engine = engine else { return }

        node.pause()
        node.stop()

        // Only disconnect/detach if the node is still attached to this engine.
        // The node may already have been removed (e.g. engine died, concurrent
        // teardown, or duplicate disconnect call).
        if node.engine === engine {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        attachedNodes.removeAll { $0.node === node }

        Logger.debug("[\(SharedAudioEngine.TAG)] Node detached")
    }

    // ════════════════════════════════════════════════════════════════════
    // Teardown
    // ════════════════════════════════════════════════════════════════════

    /// Tear down the engine completely. Called on reconfigure or module destroy.
    func teardown() {
        performSync { teardownOnQueue() }
    }

    private func teardownOnQueue() {
        // Remove observers
        NotificationCenter.default.removeObserver(
            self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: AVAudioSession.interruptionNotification, object: nil)

        // Detach all tracked nodes
        if let engine = engine {
            for info in attachedNodes {
                info.node.pause()
                info.node.stop()
                // Guard against nodes already removed from engine (e.g. engine
                // died or node was detached by a concurrent disconnect call).
                if info.node.engine === engine {
                    engine.disconnectNodeOutput(info.node)
                    engine.detach(info.node)
                }
            }
        }
        attachedNodes.removeAll()

        // Disable voice processing before stopping
        if playbackMode == .conversation || playbackMode == .voiceProcessing {
            if let engine = engine {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
        }

        engine?.stop()
        engine = nil
        isConfigured = false

        Logger.debug("[\(SharedAudioEngine.TAG)] Teardown complete")
    }

    // ════════════════════════════════════════════════════════════════════
    // Route change handling
    // ════════════════════════════════════════════════════════════════════

    /// Flag to suppress completion-handler re-entry during route-change rebuild.
    private var isRebuildingForRouteChange = false

    @objc private func handleRouteChange(notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        // Hop off AVFoundation's notification thread onto the engine queue before
        // touching the engine or session — that thread can hold an internal lock
        // when delivering this, and the queue serializes us against connect/disconnect.
        engineQueue.async { [weak self] in
            self?.handleRouteChangeOnQueue(reason: reason)
        }
    }

    private func handleRouteChangeOnQueue(reason: AVAudioSession.RouteChangeReason) {
        let routeDescription = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
        Logger.debug("[\(SharedAudioEngine.TAG)] Route changed: reason=\(reason.rawValue) → outputs=[\(routeDescription)]")

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            guard let engine = engine else {
                Logger.debug("[\(SharedAudioEngine.TAG)] Route change ignored — engine is nil")
                return
            }

            Logger.debug("[\(SharedAudioEngine.TAG)] Route change rebuild START — " +
                "engineRunning=\(engine.isRunning) attachedNodes=\(attachedNodes.count) " +
                "reason=\(reason.rawValue == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue ? "newDeviceAvailable" : "oldDeviceUnavailable")")

            // Suppress completion handlers from node.stop() re-entering the scheduling loop
            isRebuildingForRouteChange = true

            // 1. Stop all attached nodes (completion handlers fire but are gated)
            for info in attachedNodes {
                Logger.debug("[\(SharedAudioEngine.TAG)] Stopping node — isPlaying=\(info.node.isPlaying)")
                info.node.pause()
                info.node.stop()
            }

            // 2. Stop engine
            if engine.isRunning {
                engine.stop()
                Logger.debug("[\(SharedAudioEngine.TAG)] Engine stopped")
            } else {
                Logger.debug("[\(SharedAudioEngine.TAG)] Engine was already stopped")
            }

            // 3. Detach all nodes
            for info in attachedNodes {
                if info.node.engine === engine {
                    engine.disconnectNodeOutput(info.node)
                    engine.detach(info.node)
                }
            }
            Logger.debug("[\(SharedAudioEngine.TAG)] Nodes detached (\(attachedNodes.count))")

            // 4. Re-enable voice processing (resets after engine stop)
            if playbackMode == .conversation || playbackMode == .voiceProcessing {
                do {
                    try engine.inputNode.setVoiceProcessingEnabled(true)
                } catch {
                    Logger.debug("[\(SharedAudioEngine.TAG)] Voice processing re-enable failed: \(error)")
                }
            }

            // 5. Re-attach all nodes
            for info in attachedNodes {
                engine.attach(info.node)
                engine.connect(info.node, to: engine.mainMixerNode, format: info.format)
            }
            Logger.debug("[\(SharedAudioEngine.TAG)] Nodes re-attached (\(attachedNodes.count))")

            // 6. Reactivate session and restart engine with retry.
            // Voice processing mode switches the underlying audio unit (RemoteIO ↔
            // VoiceProcessingIO). This swap completes asynchronously — if we call
            // engine.start() immediately, the engine appears to start (isRunning=true)
            // but silently dies moments later, leaving nodes in isPlaying=false.
            // We retry with increasing delays to let the IO swap settle.
            let useVoiceProcessing = (playbackMode == .conversation || playbackMode == .voiceProcessing)
            let retryDelays: [TimeInterval] = useVoiceProcessing
                ? [0.15, 0.3, 0.6]   // 150ms, 300ms, 600ms pre-start delay for VP mode (+100ms post-start verify)
                : [0.0, 0.1, 0.25]   // immediate, then backoff for non-VP (+50ms post-start verify)

            self.attemptRestart(engine: engine, retryDelays: retryDelays, attempt: 0)

        case .categoryChange:
            Logger.debug("[\(SharedAudioEngine.TAG)] Audio session category changed")
        default:
            break
        }
    }

    /// Retry engine restart with backoff delays. Validates that the engine
    /// is truly running and nodes are playing before declaring success.
    /// On final failure, falls back to a full rebuild. If that also fails,
    /// tears down everything and notifies delegates via `engineDidDie`.
    private func attemptRestart(engine: AVAudioEngine, retryDelays: [TimeInterval], attempt: Int) {
        guard attempt < retryDelays.count else {
            // Exhausted in-place retries — try a full rebuild as last resort
            Logger.debug("[\(SharedAudioEngine.TAG)] All \(retryDelays.count) restart attempts failed — attempting full rebuild")
            isRebuildingForRouteChange = false
            rebuildEngine()
            return
        }

        let delay = retryDelays[attempt]
        let work = { [weak self] in
            guard let self = self, let engine = self.engine else {
                self?.isRebuildingForRouteChange = false
                return
            }

            Logger.debug("[\(SharedAudioEngine.TAG)] Restart attempt \(attempt + 1)/\(retryDelays.count)")

            // Reactivate audio session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                let newRoute = AVAudioSession.sharedInstance().currentRoute.outputs
                    .map { "\($0.portName) (\($0.portType.rawValue))" }
                    .joined(separator: ", ")
                Logger.debug("[\(SharedAudioEngine.TAG)] Session reactivated — new route=[\(newRoute)]")
            } catch {
                Logger.debug("[\(SharedAudioEngine.TAG)] setActive(true) failed: \(error)")
            }

            // Try to start engine
            do {
                if !engine.isRunning {
                    try engine.start()
                }
            } catch {
                Logger.debug("[\(SharedAudioEngine.TAG)] engine.start() threw on attempt \(attempt + 1): \(error)")
                self.attemptRestart(engine: engine, retryDelays: retryDelays, attempt: attempt + 1)
                return
            }

            // Start nodes
            for info in self.attachedNodes {
                info.node.play()
            }

            // Immediate sanity check
            let immediateRunning = engine.isRunning
            let immediateNodesPlaying = self.attachedNodes.allSatisfy { $0.node.isPlaying }
            Logger.debug("[\(SharedAudioEngine.TAG)] Attempt \(attempt + 1) immediate check — " +
                "isRunning=\(immediateRunning), allNodesPlaying=\(immediateNodesPlaying)")

            if !immediateRunning || !immediateNodesPlaying {
                // Failed immediately — no point waiting, retry now
                Logger.debug("[\(SharedAudioEngine.TAG)] Restart attempt \(attempt + 1) failed immediately")
                if engine.isRunning { engine.stop() }
                self.attemptRestart(engine: engine, retryDelays: retryDelays, attempt: attempt + 1)
                return
            }

            // Voice processing can cause the engine to die asynchronously after
            // appearing to start. Wait 100ms then re-verify before declaring success.
            let verifyDelay: TimeInterval = (self.playbackMode == .conversation || self.playbackMode == .voiceProcessing) ? 0.1 : 0.05
            self.engineQueue.asyncAfter(deadline: .now() + verifyDelay) { [weak self] in
                guard let self = self, let engine = self.engine else {
                    self?.isRebuildingForRouteChange = false
                    return
                }

                let stillRunning = engine.isRunning
                let stillPlaying = self.attachedNodes.allSatisfy { $0.node.isPlaying }

                if stillRunning && stillPlaying {
                    // Truly stable — declare success
                    self.isRebuildingForRouteChange = false
                    Logger.debug("[\(SharedAudioEngine.TAG)] Restart VERIFIED on attempt \(attempt + 1) — " +
                        "isRunning=\(stillRunning), allNodesPlaying=\(stillPlaying), " +
                        "notifying \(self.delegates.count) delegate(s)")
                    self.notifyDelegates { $0.engineDidRestartAfterRouteChange() }
                } else {
                    // Engine died after appearing to start
                    Logger.debug("[\(SharedAudioEngine.TAG)] Restart attempt \(attempt + 1) died after verification — " +
                        "isRunning=\(stillRunning), allNodesPlaying=\(stillPlaying)")
                    if engine.isRunning { engine.stop() }

                    // For VP mode, the IO swap corrupts the engine instance — further
                    // in-place retries on the same engine produce silent audio even when
                    // isRunning appears true. Skip straight to a full rebuild.
                    let isVP = (self.playbackMode == .conversation || self.playbackMode == .voiceProcessing)
                    if isVP {
                        Logger.debug("[\(SharedAudioEngine.TAG)] VP mode — skipping remaining in-place retries, going to full rebuild")
                        self.isRebuildingForRouteChange = false
                        self.rebuildEngine()
                    } else {
                        self.attemptRestart(engine: engine, retryDelays: retryDelays, attempt: attempt + 1)
                    }
                }
            }
        }

        if delay > 0 {
            Logger.debug("[\(SharedAudioEngine.TAG)] Waiting \(Int(delay * 1000))ms before attempt \(attempt + 1)")
            engineQueue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work()
        }
    }

    /// Last-resort recovery: tear down and recreate the engine from scratch.
    /// Old AVAudioPlayerNodes are NOT re-attached — they may carry stale state
    /// from the dead engine. Delegates are notified via `engineDidRebuild()` so
    /// they can create fresh nodes and re-attach.
    ///
    /// If this also fails, declare the engine dead, tear down all state, and
    /// notify delegates so they can report the failure to JS.
    private func rebuildEngine() {
        Logger.debug("[\(SharedAudioEngine.TAG)] rebuildEngine — creating fresh engine (old nodes will NOT be reused)")
        let savedMode = playbackMode

        // Full teardown (clears attachedNodes, stops engine, nils it)
        teardown()

        do {
            try configure(playbackMode: savedMode)
            // Do NOT re-attach old nodes. The VP IO swap can leave old
            // AVAudioPlayerNode instances in a broken state. Delegates must
            // create fresh nodes in their engineDidRebuild() callback.
            Logger.debug("[\(SharedAudioEngine.TAG)] rebuildEngine succeeded — notifying \(delegates.count) delegate(s) to create fresh nodes")
            notifyDelegates { $0.engineDidRebuild() }
        } catch {
            Logger.debug("[\(SharedAudioEngine.TAG)] rebuildEngine FAILED — engine is dead: \(error)")
            // Ensure everything is torn down so a future connect() starts clean
            teardown()
            let reason = "Route change recovery failed after all retries: \(error.localizedDescription)"
            notifyDelegates { $0.engineDidDie(reason: reason) }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Interruption handling
    // ════════════════════════════════════════════════════════════════════

    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        // Hop off AVFoundation's notification thread onto the engine queue.
        engineQueue.async { [weak self] in
            self?.handleInterruptionOnQueue(type: type, optionsValue: optionsValue)
        }
    }

    private func handleInterruptionOnQueue(type: AVAudioSession.InterruptionType, optionsValue: UInt) {
        if type == .began {
            Logger.debug("[\(SharedAudioEngine.TAG)] Audio session interruption began")
            notifyDelegates { $0.audioSessionInterruptionBegan() }
        } else if type == .ended {
            Logger.debug("[\(SharedAudioEngine.TAG)] Audio session interruption ended")
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard options.contains(.shouldResume) else {
                // shouldResume absent — system hints we should not restart yet.
                // Note: this flag is advisory; may be worth revisiting if it causes
                // false negatives in practice.
                Logger.debug("[\(SharedAudioEngine.TAG)] shouldResume not set — skipping restart")
                notifyDelegates { $0.audioSessionResumeDenied() }
                return
            }
            // Reactivate session and restart engine
            try? AVAudioSession.sharedInstance().setActive(true)
            if let engine = engine, !engine.isRunning {
                do {
                    try engine.start()
                    for info in attachedNodes {
                        info.node.play()
                    }
                } catch {
                    Logger.debug("[\(SharedAudioEngine.TAG)] Failed to restart after interruption: \(error)")
                }
            }
            notifyDelegates { $0.audioSessionInterruptionEnded() }
        }
    }

    deinit {
        // At dealloc there are no other references, so no concurrency — run the
        // body directly rather than dispatching onto the queue during teardown.
        teardownOnQueue()
    }
}

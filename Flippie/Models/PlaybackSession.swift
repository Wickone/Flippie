import SwiftUI

/// Owns the preview UIView for the lifetime of the editor, not a sheet.
@MainActor
final class PlaybackSession: ObservableObject {
    enum Readiness: Equatable { case empty, loading, ready, failed }
    let player = VersionedLottiePlayerView()
    @Published private(set) var readiness: Readiness = .empty
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var totalFrames: Double = 0
    @Published private(set) var hasAnimation = false
    @Published var speed: Double = 1 { didSet { player.animationSpeed = speed } }
    @Published var loopMode: PlayerLoopMode = .loop { didSet { player.loopMode = loopMode } }
    var currentFrame: Double { progress * totalFrames }
    private var timer: Timer?
    private var loadGeneration = UUID()
    private var pendingCandidate: VersionedLottiePlayerView.PreparedAnimation?
    private var liveReadiness: Readiness = .empty
    private var isSceneActive = true
    private var resumeOnActivation = false
    @Published private(set) var pendingRuntime: LottieRuntimeVersion?
    private var runtimeSwitchGeneration: UUID?
    private let waitForCandidate: (VersionedLottiePlayerView.PreparedAnimation) async throws -> Void

    init(waitForCandidate: @escaping (VersionedLottiePlayerView.PreparedAnimation) async throws -> Void = { try await $0.waitUntilReady() }) {
        self.waitForCandidate = waitForCandidate
    }

    func switchRuntime(data: Data, runtime: LottieRuntimeVersion, baseURL: URL?) async throws {
        let generation = UUID()
        runtimeSwitchGeneration = generation
        pendingRuntime = runtime
        defer {
            if generation == runtimeSwitchGeneration {
                runtimeSwitchGeneration = nil
                pendingRuntime = nil
            }
        }
        do {
            try await load(data: data, runtime: runtime, baseURL: baseURL, preservingPlayback: true)
        } catch {
            guard generation == runtimeSwitchGeneration else { throw CancellationError() }
            throw error
        }
        guard generation == runtimeSwitchGeneration else { throw CancellationError() }
    }
    var isTrackingProgress: Bool { timer?.isValid == true }

    func load(data: Data, runtime: LottieRuntimeVersion, baseURL: URL?, preservingPlayback: Bool = false) async throws {
        if !preservingPlayback { cancelRuntimeSwitch() }
        let generation = UUID()
        loadGeneration = generation
        pendingCandidate?.invalidate()
        pendingCandidate = nil
        readiness = .loading
        do {
            let candidate = try player.prepare(data: data, runtime: runtime, baseURL: baseURL)
            pendingCandidate = candidate
            try await waitForCandidate(candidate)
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            pendingCandidate = nil
            let oldProgress = preservingPlayback ? player.currentProgress : 0
            let shouldPlay = preservingPlayback && (isPlaying || resumeOnActivation)
            stopTracking()
            player.install(candidate)
            player.backgroundColor = .clear
            player.animationSpeed = speed
            player.loopMode = loopMode
            totalFrames = max(0, candidate.range.end - candidate.range.start)
            hasAnimation = true
            isPlaying = false
            resumeOnActivation = false
            player.currentProgress = oldProgress
            progress = oldProgress
            liveReadiness = .ready
            readiness = .ready
            if shouldPlay { play() }
        } catch {
            if generation == loadGeneration {
                pendingCandidate?.invalidate()
                pendingCandidate = nil
                readiness = liveReadiness
            }
            throw error
        }
    }
    func play() {
        guard hasAnimation, !isPlaying else { return }
        guard isSceneActive else { resumeOnActivation = true; return }
        if progress >= 1 { player.currentProgress = 0; progress = 0 }
        resumeOnActivation = false
        isPlaying = true
        player.play { [weak self] finished in
            guard let self, self.isPlaying else { return }
            if finished { self.progress = 1 }
            else {
                self.updateProgress()
                self.liveReadiness = .failed
                self.readiness = .failed
            }
            self.isPlaying = false
            self.stopTracking()
        }
        if isPlaying { startTracking() }
    }
    func pause() {
        resumeOnActivation = false
        player.pause()
        updateProgress()
        isPlaying = false
        stopTracking()
    }
    func seek(progress: Double) {
        guard hasAnimation, progress.isFinite else { return }
        pause()
        self.progress = min(max(progress, 0), 1)
        player.currentProgress = self.progress
    }
    func step(by frames: Double) {
        guard totalFrames > 0, frames.isFinite else { return }
        pause()
        seek(progress: (currentFrame + frames) / totalFrames)
    }
    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        if !active {
            let wasPlaying = isPlaying
            pause()
            resumeOnActivation = wasPlaying
        } else if resumeOnActivation {
            play()
        }
    }
    func close() {
        cancelRuntimeSwitch()
        loadGeneration = UUID()
        pendingCandidate?.invalidate()
        pendingCandidate = nil
        resumeOnActivation = false
        stopTracking()
        player.unload()
        isPlaying = false
        hasAnimation = false
        progress = 0
        totalFrames = 0
        liveReadiness = .empty
        readiness = .empty
    }
    private func updateProgress() {
        guard hasAnimation else { return }
        progress = min(max(player.currentProgress, 0), 1)
    }
    private func cancelRuntimeSwitch() {
        runtimeSwitchGeneration = nil
        pendingRuntime = nil
    }
    private func startTracking() {
        stopTracking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stopTracking() {
        timer?.invalidate()
        timer = nil
    }
    deinit { timer?.invalidate() }
}

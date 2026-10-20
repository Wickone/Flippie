import SwiftUI
import UIKit
import Lottie300
import Lottie350
import Lottie400
import Lottie461

enum PlayerLoopMode: String, CaseIterable, Hashable, Codable {
    case playOnce
    case loop
    case autoReverse
}

enum LottieRenderingMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case coreAnimation = "Core Animation"
    case mainThread = "Main Thread"

    var id: String { rawValue }

    var configuration: Lottie461.LottieConfiguration {
        switch self {
        case .automatic:
            Lottie461.LottieConfiguration(renderingEngine: .automatic)
        case .coreAnimation:
            Lottie461.LottieConfiguration(renderingEngine: .coreAnimation)
        case .mainThread:
            Lottie461.LottieConfiguration(renderingEngine: .mainThread)
        }
    }
}

struct AnimationFrameRange {
    let start: Double
    let end: Double
    let duration: Double
}

@MainActor
final class VersionedLottiePlayerView: UIView {
    fileprivate enum Engine {
        case v300(Lottie300.AnimationView)
        case v350(Lottie350.LottieAnimationView)
        case v400(Lottie400.LottieAnimationView)
        case v461(Lottie461.LottieAnimationView)
        case web(LottieWebPlayerView)
    }

    private var engine: Engine?
    private(set) var timeline = AnimationTimeline(startFrame: 0, endFrame: 0, frameRate: 0)
    private var playbackGeneration = UUID()

    struct PreparedAnimation {
        fileprivate let engine: Engine
        let range: AnimationFrameRange
        let runtime: LottieRuntimeVersion
        let renderingMode: LottieRenderingMode

        @MainActor func waitUntilReady() async throws {
            if case .web(let view) = engine {
                try await view.waitForPlaybackReadiness()
            }
        }

        @MainActor func invalidate() {
            if case .web(let view) = engine { view.invalidate() }
        }
    }
    private(set) var runtime: LottieRuntimeVersion = .embedded
    private(set) var renderingMode: LottieRenderingMode = .automatic

    var loopMode: PlayerLoopMode = .loop {
        didSet { applyLoopMode() }
    }

    var animationSpeed: Double = 1 {
        didSet { applySpeed() }
    }

    var currentRenderingEngineName: String {
        if case .web = engine {
            return "lottie-web SVG"
        }
        if case .v461(let view) = engine {
            return view.currentRenderingEngine?.rawValue ?? renderingMode.rawValue
        }
        return "Main Thread"
    }

    func load(
        data: Data,
        runtime: LottieRuntimeVersion,
        renderingMode: LottieRenderingMode = .automatic,
        baseURL: URL? = nil
    ) throws -> AnimationFrameRange {
        let candidate = try prepare(data: data, runtime: runtime, renderingMode: renderingMode, baseURL: baseURL)
        install(candidate)
        return candidate.range
    }

    func prepare(
        data: Data,
        runtime: LottieRuntimeVersion,
        renderingMode: LottieRenderingMode = .automatic,
        baseURL: URL? = nil
    ) throws -> PreparedAnimation {
        try LottieImportService.validate(data)
        let nextEngine: Engine
        let range: AnimationFrameRange

        if AnimationDocument.requiresWebRenderer(data) {
            let webPlayer = LottieWebPlayerView()
            range = try webPlayer.load(data: data, baseURL: baseURL)
            nextEngine = .web(webPlayer)
        } else {
          switch runtime {
        case .v300:
            let animation = try JSONDecoder().decode(Lottie300.Animation.self, from: data)
            nextEngine = .v300(Lottie300.AnimationView(
                animation: animation,
                imageProvider: baseURL.map(Lottie300FileImageProvider.init(baseURL:))
            ))
            range = Self.range(
                start: animation.startFrame,
                end: animation.endFrame,
                duration: animation.duration
            )
        case .v350:
            let animation = try Lottie350.LottieAnimation.from(data: data)
            nextEngine = .v350(Lottie350.LottieAnimationView(
                animation: animation,
                imageProvider: baseURL.map(Lottie350FileImageProvider.init(baseURL:))
            ))
            range = Self.range(
                start: animation.startFrame,
                end: animation.endFrame,
                duration: animation.duration
            )
        case .v400:
            let animation = try Lottie400.LottieAnimation.from(data: data)
            nextEngine = .v400(Lottie400.LottieAnimationView(
                animation: animation,
                imageProvider: baseURL.map(Lottie400FileImageProvider.init(baseURL:))
            ))
            range = Self.range(
                start: animation.startFrame,
                end: animation.endFrame,
                duration: animation.duration
            )
        case .v461:
            let animation = try Lottie461.LottieAnimation.from(data: data)
            nextEngine = .v461(Lottie461.LottieAnimationView(
                animation: animation,
                imageProvider: baseURL.map(Lottie461FileImageProvider.init(baseURL:)),
                configuration: renderingMode.configuration
            ))
            range = Self.range(
                start: animation.startFrame,
                end: animation.endFrame,
                duration: animation.duration
            )
          }
        }

        return PreparedAnimation(engine: nextEngine, range: range, runtime: runtime, renderingMode: renderingMode)
    }

    func install(_ candidate: PreparedAnimation) {
        stop()
        if case .web(let old) = engine { old.invalidate() }
        engineView?.removeFromSuperview()
        engine = candidate.engine
        runtime = candidate.runtime
        renderingMode = candidate.renderingMode
        let range = candidate.range
        timeline = AnimationTimeline(startFrame: range.start, endFrame: range.end,
            frameRate: range.duration > 0 ? (range.end - range.start) / range.duration : 0)

        guard let view = engineView else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyLoopMode()
        applySpeed()
    }

    var currentProgress: Double {
        get {
            switch engine {
            case .v300(let view): Double(view.realtimeAnimationProgress)
            case .v350(let view): Double(view.realtimeAnimationProgress)
            case .v400(let view): Double(view.realtimeAnimationProgress)
            case .v461(let view): Double(view.realtimeAnimationProgress)
            case .web(let view): view.currentProgress
            case nil: 0
            }
        }
        set {
            let progress = timeline.progress(forAbsoluteFrame: timeline.absoluteFrame(forProgress: newValue))
            switch engine {
            case .v300(let view): view.currentProgress = CGFloat(progress)
            case .v350(let view): view.currentProgress = CGFloat(progress)
            case .v400(let view): view.currentProgress = CGFloat(progress)
            case .v461(let view): view.currentProgress = CGFloat(progress)
            case .web(let view): view.setProgress(progress)
            case nil: break
            }
        }
    }

    var currentFrame: Double {
        get {
            switch engine {
            case .v300(let view): Double(view.realtimeAnimationFrame)
            case .v350(let view): Double(view.realtimeAnimationFrame)
            case .v400(let view): Double(view.realtimeAnimationFrame)
            case .v461(let view): Double(view.realtimeAnimationFrame)
            case .web(let view): view.currentFrame
            case nil: 0
            }
        }
        set {
            let frame = timeline.absoluteFrame(forProgress: timeline.progress(forAbsoluteFrame: newValue))
            switch engine {
            case .v300(let view): view.currentFrame = CGFloat(frame)
            case .v350(let view): view.currentFrame = CGFloat(frame)
            case .v400(let view): view.currentFrame = CGFloat(frame)
            case .v461(let view): view.currentFrame = CGFloat(frame)
            case .web(let view): view.setFrame(frame)
            case nil: break
            }
        }
    }

    func play(completion: ((Bool) -> Void)? = nil) {
        let generation = UUID()
        playbackGeneration = generation
        let finished: (Bool) -> Void = { [weak self] success in
            guard let self, self.playbackGeneration == generation else { return }
            completion?(success)
        }
        switch engine {
        case .v300(let view): view.play(fromProgress: 0, toProgress: 1, completion: finished)
        case .v350(let view): view.play(fromProgress: 0, toProgress: 1, completion: finished)
        case .v400(let view): view.play(fromProgress: 0, toProgress: 1, completion: finished)
        case .v461(let view): view.play(fromProgress: 0, toProgress: 1, completion: finished)
        case .web(let view): view.play(completion: finished)
        case nil: break
        }
    }

    func pause() {
        playbackGeneration = UUID()
        switch engine {
        case .v300(let view): view.pause()
        case .v350(let view): view.pause()
        case .v400(let view): view.pause()
        case .v461(let view): view.pause()
        case .web(let view): view.pause()
        case nil: break
        }
    }

    func stop() {
        playbackGeneration = UUID()
        switch engine {
        case .v300(let view): view.stop()
        case .v350(let view): view.stop()
        case .v400(let view): view.stop()
        case .v461(let view): view.stop()
        case .web(let view): view.stop()
        case nil: break
        }
        currentFrame = timeline.startFrame
    }

    private var engineView: UIView? {
        switch engine {
        case .v300(let view): view
        case .v350(let view): view
        case .v400(let view): view
        case .v461(let view): view
        case .web(let view): view
        case nil: nil
        }
    }

    func unload() {
        stop()
        if case .web(let view) = engine { view.invalidate() }
        engineView?.removeFromSuperview()
        engine = nil
        timeline = AnimationTimeline(startFrame: 0, endFrame: 0, frameRate: 0)
    }

    private func applySpeed() {
        let speed = CGFloat(animationSpeed)
        switch engine {
        case .v300(let view): view.animationSpeed = speed
        case .v350(let view): view.animationSpeed = speed
        case .v400(let view): view.animationSpeed = speed
        case .v461(let view): view.animationSpeed = speed
        case .web(let view): view.setSpeed(animationSpeed)
        case nil: break
        }
    }

    private func applyLoopMode() {
        switch engine {
        case .v300(let view):
            switch loopMode {
            case .playOnce: view.loopMode = .playOnce
            case .loop: view.loopMode = .loop
            case .autoReverse: view.loopMode = .autoReverse
            }
        case .v350(let view):
            switch loopMode {
            case .playOnce: view.loopMode = .playOnce
            case .loop: view.loopMode = .loop
            case .autoReverse: view.loopMode = .autoReverse
            }
        case .v400(let view):
            switch loopMode {
            case .playOnce: view.loopMode = .playOnce
            case .loop: view.loopMode = .loop
            case .autoReverse: view.loopMode = .autoReverse
            }
        case .v461(let view):
            switch loopMode {
            case .playOnce: view.loopMode = .playOnce
            case .loop: view.loopMode = .loop
            case .autoReverse: view.loopMode = .autoReverse
            }
        case .web(let view):
            view.setLoopMode(loopMode)
        case nil:
            break
        }
    }

    func prepareFrame(progress: Double) async throws {
        if case .web(let view) = engine {
            try await view.prepareFrame(progress: progress)
        } else {
            currentFrame = timeline.renderableFrame(forProgress: progress)
        }
    }

    var usesWebRenderer: Bool {
        if case .web = engine { return true }
        return false
    }

    func webSnapshotCGImage(size: CGSize) async throws -> CGImage? {
        guard case .web(let view) = engine else { return nil }
        return try await view.snapshotCGImage(size: size)
    }

    private static func range(
        start: CGFloat,
        end: CGFloat,
        duration: TimeInterval
    ) -> AnimationFrameRange {
        AnimationFrameRange(
            start: Double(start),
            end: Double(end),
            duration: Double(duration)
        )
    }
}

private final class Lottie300FileImageProvider: Lottie300.AnimationImageProvider {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func imageForAsset(asset: Lottie300.ImageAsset) -> CGImage? {
        LottieAssetResolver.image(
            name: asset.name,
            directory: asset.directory,
            baseURL: baseURL
        )
    }
}

private final class Lottie350FileImageProvider: Lottie350.AnimationImageProvider {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func imageForAsset(asset: Lottie350.ImageAsset) -> CGImage? {
        LottieAssetResolver.image(
            name: asset.name,
            directory: asset.directory,
            baseURL: baseURL
        )
    }
}

private final class Lottie400FileImageProvider: Lottie400.AnimationImageProvider {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func imageForAsset(asset: Lottie400.ImageAsset) -> CGImage? {
        LottieAssetResolver.image(
            name: asset.name,
            directory: asset.directory,
            baseURL: baseURL
        )
    }
}

private final class Lottie461FileImageProvider: Lottie461.AnimationImageProvider {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func imageForAsset(asset: Lottie461.ImageAsset) -> CGImage? {
        LottieAssetResolver.image(
            name: asset.name,
            directory: asset.directory,
            baseURL: baseURL
        )
    }
}

struct LottieView: UIViewRepresentable {
    let animationView: VersionedLottiePlayerView

    func makeUIView(context: Context) -> VersionedLottiePlayerView {
        animationView
    }

    func updateUIView(_ uiView: VersionedLottiePlayerView, context: Context) {}
}

struct RendererComparisonView: View {
    let data: Data
    let formatVersion: String?
    var baseURL: URL? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var coreAnimationView = VersionedLottiePlayerView()
    @State private var mainThreadView = VersionedLottiePlayerView()
    @State private var progress = 0.0
    @State private var isPlaying = false
    @State private var coreAnimationError: String?
    @State private var mainThreadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        metadataLabel("Format", value: formatVersion ?? "Missing")
                        Spacer()
                        metadataLabel("lottie-ios", value: "4.6.1")
                    }

                    rendererCard(
                        title: "Core Animation",
                        player: coreAnimationView,
                        error: coreAnimationError
                    )

                    rendererCard(
                        title: "Main Thread",
                        player: mainThreadView,
                        error: mainThreadError
                    )

                    Slider(value: $progress, in: 0...1) { editing in
                        if !editing {
                            coreAnimationView.currentProgress = progress
                            mainThreadView.currentProgress = progress
                        }
                    }

                    Button {
                        togglePlayback()
                    } label: {
                        Label(
                            isPlaying ? "Pause Both" : "Play Both",
                            systemImage: isPlaying ? "pause.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle("Renderer Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: loadRenderers)
            .onDisappear {
                coreAnimationView.stop()
                mainThreadView.stop()
            }
        }
    }

    private func rendererCard(
        title: String,
        player: VersionedLottiePlayerView,
        error: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(player.currentRenderingEngineName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error {
                ContentUnavailableView(
                    "Renderer failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(height: 240)
            } else {
                LottieView(animationView: player)
                    .frame(height: 240)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func metadataLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func loadRenderers() {
        do {
            _ = try coreAnimationView.load(
                data: data,
                runtime: .v461,
                renderingMode: .coreAnimation,
                baseURL: baseURL
            )
            coreAnimationView.loopMode = .loop
        } catch {
            coreAnimationError = error.localizedDescription
        }

        do {
            _ = try mainThreadView.load(
                data: data,
                runtime: .v461,
                renderingMode: .mainThread,
                baseURL: baseURL
            )
            mainThreadView.loopMode = .loop
        } catch {
            mainThreadError = error.localizedDescription
        }
    }

    private func togglePlayback() {
        if isPlaying {
            coreAnimationView.pause()
            mainThreadView.pause()
        } else {
            coreAnimationView.currentProgress = progress
            mainThreadView.currentProgress = progress
            coreAnimationView.play()
            mainThreadView.play()
        }
        isPlaying.toggle()
    }
}

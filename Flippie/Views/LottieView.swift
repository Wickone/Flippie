import SwiftUI
import UIKit
import Lottie300
import Lottie350
import Lottie400
import Lottie461

enum PlayerLoopMode: CaseIterable, Hashable {
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
    private enum Engine {
        case v300(Lottie300.AnimationView)
        case v350(Lottie350.LottieAnimationView)
        case v400(Lottie400.LottieAnimationView)
        case v461(Lottie461.LottieAnimationView)
        case web(LottieWebPlayerView)
    }

    private var engine: Engine?
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

        stop()
        engineView?.removeFromSuperview()
        engine = nextEngine
        self.runtime = runtime
        self.renderingMode = renderingMode

        guard let view = engineView else { return range }
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
        return range
    }

    var currentProgress: Double {
        get {
            switch engine {
            case .v300(let view): Double(view.currentProgress)
            case .v350(let view): Double(view.currentProgress)
            case .v400(let view): Double(view.currentProgress)
            case .v461(let view): Double(view.currentProgress)
            case .web(let view): view.currentProgress
            case nil: 0
            }
        }
        set {
            switch engine {
            case .v300(let view): view.currentProgress = CGFloat(newValue)
            case .v350(let view): view.currentProgress = CGFloat(newValue)
            case .v400(let view): view.currentProgress = CGFloat(newValue)
            case .v461(let view): view.currentProgress = CGFloat(newValue)
            case .web(let view): view.setProgress(newValue)
            case nil: break
            }
        }
    }

    var currentFrame: Double {
        get {
            switch engine {
            case .v300(let view): Double(view.currentFrame)
            case .v350(let view): Double(view.currentFrame)
            case .v400(let view): Double(view.currentFrame)
            case .v461(let view): Double(view.currentFrame)
            case .web(let view): view.currentFrame
            case nil: 0
            }
        }
        set {
            switch engine {
            case .v300(let view): view.currentFrame = CGFloat(newValue)
            case .v350(let view): view.currentFrame = CGFloat(newValue)
            case .v400(let view): view.currentFrame = CGFloat(newValue)
            case .v461(let view): view.currentFrame = CGFloat(newValue)
            case .web(let view): view.setFrame(newValue)
            case nil: break
            }
        }
    }

    func play() {
        switch engine {
        case .v300(let view): view.play()
        case .v350(let view): view.play()
        case .v400(let view): view.play()
        case .v461(let view): view.play()
        case .web(let view): view.play()
        case nil: break
        }
    }

    func pause() {
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
        switch engine {
        case .v300(let view): view.stop()
        case .v350(let view): view.stop()
        case .v400(let view): view.stop()
        case .v461(let view): view.stop()
        case .web(let view): view.stop()
        case nil: break
        }
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
            currentProgress = progress
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

private enum LottieImageAssetResolver {
    static func image(name: String, directory: String, baseURL: URL) -> CGImage? {
        if let embeddedImage = embeddedImage(named: name) {
            return embeddedImage
        }

        for url in candidateURLs(name: name, directory: directory, baseURL: baseURL) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let image = UIImage(contentsOfFile: url.path)?.cgImage else {
                continue
            }
            return image
        }
        return nil
    }

    private static func embeddedImage(named name: String) -> CGImage? {
        guard name.hasPrefix("data:") else { return nil }

        if let url = URL(string: name),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data)?.cgImage {
            return image
        }

        guard let commaIndex = name.firstIndex(of: ",") else { return nil }
        let payload = String(name[name.index(after: commaIndex)...])
        let data: Data?
        if name[..<commaIndex].contains(";base64") {
            data = Data(base64Encoded: payload)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        return data.flatMap { UIImage(data: $0)?.cgImage }
    }

    private static func candidateURLs(
        name: String,
        directory: String,
        baseURL: URL
    ) -> [URL] {
        let rawCandidates = [
            name,
            joined(directory, name),
            joined("images", name),
            joined("i", name),
            joined("assets", name),
        ].compactMap { $0 }

        var result: [URL] = []
        var seen = Set<String>()
        for candidate in rawCandidates {
            guard let safePath = safeRelativePath(candidate) else { continue }
            let url = safePath.reduce(baseURL) { partialURL, component in
                partialURL.appendingPathComponent(component)
            }
            if seen.insert(url.path).inserted {
                result.append(url)
            }
        }
        return result
    }

    private static func joined(_ directory: String, _ name: String) -> String? {
        guard !directory.isEmpty else { return name }
        return (directory as NSString).appendingPathComponent(name)
    }

    private static func safeRelativePath(_ rawPath: String) -> [String]? {
        let normalizedPath = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty,
              !normalizedPath.hasPrefix("/"),
              !normalizedPath.hasPrefix("~"),
              URL(string: normalizedPath)?.scheme == nil else {
            return nil
        }

        let components = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }
}

private final class Lottie300FileImageProvider: Lottie300.AnimationImageProvider {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func imageForAsset(asset: Lottie300.ImageAsset) -> CGImage? {
        LottieImageAssetResolver.image(
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
        LottieImageAssetResolver.image(
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
        LottieImageAssetResolver.image(
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
        LottieImageAssetResolver.image(
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
                renderingMode: .coreAnimation
            )
            coreAnimationView.loopMode = .loop
        } catch {
            coreAnimationError = error.localizedDescription
        }

        do {
            _ = try mainThreadView.load(
                data: data,
                runtime: .v461,
                renderingMode: .mainThread
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

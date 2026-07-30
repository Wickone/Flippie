import SwiftUI
import UIKit

private func softHaptic() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.75)
}

struct ContentView: View {
    @StateObject private var document = AnimationDocument()
    @State private var showingBundledAnimations = false
    @State private var showingExportSheet = false
    @State private var showingEditSheet = false
    @State private var showingRendererComparison = false
    @State private var showingFileImporter = false
    @State private var fileImportMode: FileImportMode = .animation
    @State private var showingPlaybackSettingsDialog = false
    @State private var showingAlert = false
    @State private var importReport: LottieImportReport?
    @State private var pendingAssetRepairReport: LottieImportReport?
    @State private var importCompatibilityResults: [LottieCompatibilityResult] = []
    @State private var alertMessage = ""
    @State private var statusMessage = ""
    @State private var isImporting = false
    @State private var isRepairingMissingAssets = false
    @State private var isSwitchingRuntime = false
    @State private var pendingRuntime: LottieRuntimeVersion?
    @State private var runtimeStatusMessage = ""
    @State private var emptyGreetingIndex = 0
    @State private var emptyTitle = "Import lottie"
    @State private var emptyMessage = "Welcome to your flippie! Tap this text to choose a ready-made lottie, see how it fits your flippie, and add it when you’re ready."
    @State private var editingEmptyCopy = false
    @State private var previousControlAnimationTick = 0
    @State private var playControlAnimationTick = 0
    @State private var nextControlAnimationTick = 0
    @State private var loadedTabSelection: LoadedActionTab = .preview
    
    // Animation player state
    @State private var animationView = VersionedLottiePlayerView()
    @State private var hasAnimation = false
    @State private var isPlaying = false
    @State private var currentFrame: Double = 0
    @State private var totalFrames: Double = 100
    @State private var animationSpeed: Double = 1.0
    @State private var progressTimer: Timer?
    
    // Frame mapping for offset animations
    @State private var animationStartFrame: Double = 0
    @State private var animationEndFrame: Double = 100
    
    // Animation properties
    @State private var loopMode: PlayerLoopMode = .loop

    private let emptyGreetings = [
        "Hi! 👋",
        "Drop a JSON",
        "Ready to test?",
        "Let’s animate"
    ]
    
    private var animationPreviewArea: some View {
        VStack(spacing: 16) {
            if hasAnimation {
                runtimeSelector
                    .padding(.horizontal)
            }

            // Animation Display
            animationDisplayView
                .padding(.horizontal)
            
            // Playback Controls (closer to preview)
            if hasAnimation {
                playbackControls
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // Edit Button (moved to bottom)
            if hasAnimation {
                editButton
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
    }
    
    private var animationDisplayView: some View {
        ZStack {
            if hasAnimation {
                LottieView(animationView: animationView)
                    .frame(maxWidth: .infinity, maxHeight: 440)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 440)
                    .overlay {
                        VStack(spacing: 12) {
                            if isImporting {
                                ProgressView()
                                    .controlSize(.large)
                                Text("Validating Lottie JSON…")
                                    .font(.headline)
                            } else {
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.gray)
                                Text("Import Lottie Animation")
                                    .foregroundColor(.gray)
                                    .font(.headline)
                                Button("Choose JSON") {
                                    softHaptic()
                                    fileImportMode = .animation
                                    showingFileImporter = true
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if !statusMessage.isEmpty {
                                Text(statusMessage)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                    }
            }

            if isSwitchingRuntime {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading \((pendingRuntime ?? document.selectedRuntime).title)…")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }
    
    private var editButton: some View {
        Button(action: {
            softHaptic()
            showingEditSheet = true
        }) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("Edit")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .cornerRadius(12)
        }
    }
    
    private var playbackControls: some View {
        VStack(spacing: 32) {
            progressBarSection
            controlButtons
        }
        .padding(.vertical, 16)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(16)
    }
    
    private var progressBarSection: some View {
        VStack(spacing: 12) {
            // Frame info and speed control
            HStack {
                Text("Frame \(Int(currentFrame)) / \(Int(totalFrames))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                Spacer()
                Menu {
                    Button("0.5x") { setSpeed(0.5) }
                    Button("1x") { setSpeed(1.0) }
                    Button("1.5x") { setSpeed(1.5) }
                    Button("2x") { setSpeed(2.0) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                        Text(String(format: "%.1fx", animationSpeed))
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                    .fontWeight(.medium)
                }
                .disabled(!hasAnimation)
            }
            
            // Progress slider
            Slider(value: $currentFrame, in: 0...totalFrames) { editing in
                if !editing {
                    seekToFrame(currentFrame)
                }
            }
            .disabled(!hasAnimation)
            .accentColor(.blue)
            
            // Animation properties
            HStack(spacing: 16) {
                Text("Mode:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Menu {
                    Button(action: { setLoopMode(.playOnce) }) {
                        HStack {
                            Text("Play Once")
                            if loopMode == .playOnce {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Button(action: { setLoopMode(.loop) }) {
                        HStack {
                            Text("Loop")
                            if loopMode == .loop {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Button(action: { setLoopMode(.autoReverse) }) {
                        HStack {
                            Text("Back-and-Forth")
                            if loopMode == .autoReverse {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: loopModeIcon(loopMode))
                        Text(loopModeText(loopMode))
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                    .fontWeight(.medium)
                }
                .disabled(!hasAnimation)
                
                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }
    
    private var controlButtons: some View {
        HStack(spacing: 40) {
            // Previous Frame
            Button(action: previousFrame) {
                Image(systemName: "backward.frame.fill")
                    .font(.title)
                    .foregroundColor(.blue)
            }
            .disabled(!hasAnimation)
            
            // Play/Pause
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 42)) // 1.5x larger than .title (28pt)
                    .foregroundColor(.blue)
            }
            .disabled(!hasAnimation)
            
            // Next Frame
            Button(action: nextFrame) {
                Image(systemName: "forward.frame.fill")
                    .font(.title)
                    .foregroundColor(.blue)
            }
            .disabled(!hasAnimation)
        }
        .padding(.horizontal, 20)
    }

    private var runtimeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Lottie Runtime", selection: runtimeSelection) {
                ForEach(LottieRuntimeVersion.allCases) { version in
                    Text(version.shortTitle).tag(version)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSwitchingRuntime)

            HStack {
                Text("Format \(document.metadata?.formatVersion ?? "Missing")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Test Renderers") {
                    softHaptic()
                    showingRendererComparison = true
                }
                .buttonStyle(.borderless)
                .disabled(
                    document.selectedRuntime != .v461
                        || document.renderedData.map(
                            AnimationDocument.requiresWebRenderer
                        ) == true
                )
            }

            Text(document.selectedRuntime.comparisonNote)
                .font(.caption)
                .foregroundColor(.secondary)

            if !runtimeStatusMessage.isEmpty {
                Label(
                    runtimeStatusMessage,
                    systemImage: document.hasRenderingLimitations
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(document.hasRenderingLimitations ? .orange : .green)
            }

            if let limitation = document.renderingDiagnostics.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(document.metadata?.layerCount ?? 0) layers imported")
                        Spacer()
                        Text("Reference renderer")
                            .fontWeight(.semibold)
                    }
                    .font(.caption)

                    Text(limitation.message)
                        .font(.caption)

                    Text("Version switching is bypassed for this effect because the same SVG fallback is used for every lottie-ios runtime.")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
                .padding(10)
                .background(
                    Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
        .padding(.top, 8)
    }

    private var runtimeSelection: Binding<LottieRuntimeVersion> {
        Binding(
            get: { document.selectedRuntime },
            set: {
                softHaptic()
                switchRuntime(to: $0)
            }
        )
    }

    private var mainEditorScreen: some View {
        loadedEditorScreen
    }

    private var flippieNavigationLogo: some View {
        HStack(alignment: .top, spacing: 3) {
            Text("flippie")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .kerning(-0.8)

            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .black))
                .offset(y: 7)
        }
        .foregroundStyle(.white.opacity(0.92))
        .accessibilityLabel("Flippie")
    }

    @ViewBuilder
    private var loadedEditorScreen: some View {
        loadedPreviewTabContent
    }

    private var loadedPreviewTabContent: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let scale = width / 393
            let previewWidth = min(width - 32, 361 * scale)
            let previewHeight = min(362 * scale, height * 0.46)
            let previewTop = 132 * scale
            let previewCenterY = previewTop + (previewHeight / 2)
            let infoCenterY = previewTop + previewHeight + (22 * scale)
            let controlsCenterY = previewTop + previewHeight + (132 * scale)
            let tabBarWidth = min(width - (88 * scale), 288 * scale)
            let tabBarHeight = 64 * scale
            let tabBarCenterY = height - proxy.safeAreaInsets.bottom - (88 * scale)
            ZStack {
                emptyScreenBackground
                    .ignoresSafeArea()

                loadedBackButton
                    .position(x: 38 * scale, y: 84 * scale)

                loadedProfileButton
                    .position(x: width - (38 * scale), y: 84 * scale)

                flippieNavigationLogo
                    .position(x: width / 2, y: 88 * scale)

                loadedPreviewCard(width: previewWidth, height: previewHeight, scale: scale)
                    .position(x: width / 2, y: previewCenterY)

                animationInfoPill
                    .position(x: width / 2, y: infoCenterY)

                loadedPlaybackControls(scale: scale)
                    .position(x: width / 2, y: controlsCenterY)

                loadedGlassTabBar(width: tabBarWidth, height: tabBarHeight, scale: scale)
                    .position(x: width / 2, y: tabBarCenterY)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var loadedBackButton: some View {
        Button {
            softHaptic()
            closeCurrentAnimation()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.02, green: 0.02, blue: 0.10))
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
                .liquidGlassBackground(shape: Circle(), cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private var loadedProfileButton: some View {
        Button {
            softHaptic()
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color(red: 0.02, green: 0.02, blue: 0.10))
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
                .liquidGlassBackground(shape: Circle(), cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }

    private func loadedPreviewCard(width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            CheckerboardView(squareSize: 11 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 58 * scale, style: .continuous))

            LottieView(animationView: animationView)
                .padding(22 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 58 * scale, style: .continuous))
                .allowsHitTesting(false)

            if isSwitchingRuntime {
                RoundedRectangle(cornerRadius: 58 * scale, style: .continuous)
                    .fill(.ultraThinMaterial)

                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading \((pendingRuntime ?? document.selectedRuntime).title)…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding()
            }

            playbackSettingsMenu(scale: scale)
                .padding(.trailing, 17 * scale)
                .padding(.bottom, 17 * scale)
                .zIndex(2)
        }
        .frame(width: width, height: height)
        .shadow(color: Color(red: 0.0, green: 0.06, blue: 0.55).opacity(0.24), radius: 22, x: 0, y: 18)
    }

    private func playbackSettingsMenu(scale: CGFloat) -> some View {
        Button {
            softHaptic()
            showingPlaybackSettingsDialog = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17 * scale, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.90))
                .frame(width: 44 * scale, height: 44 * scale)
                .previewGlassBackground(shape: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback settings")
    }

    private var animationInfoPill: some View {
        Text(animationInfoText)
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Color.white.opacity(0.18))
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
            }
    }

    private var animationInfoText: String {
        guard let metadata = document.metadata else {
            return "0/0 • 0,00s • 0 fps • Canvas 0x0"
        }

        let frame = min(Int(currentFrame.rounded()), Int(totalFrames.rounded()))
        let total = Int(totalFrames.rounded())
        let duration = String(format: "%.2fs", metadata.duration).replacingOccurrences(of: ".", with: ",")
        let fps = Int(metadata.frameRate.rounded())
        return "\(frame)/\(total) • \(duration) • \(fps) fps • Canvas \(metadata.width)x\(metadata.height)"
    }

    @ViewBuilder
    private func loadedPlaybackControls(scale: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 32 * scale) {
                loadedPlaybackControlsContent(scale: scale)
            }
        } else {
            loadedPlaybackControlsContent(scale: scale)
        }
    }

    private func loadedPlaybackControlsContent(scale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 32 * scale) {
            loadedControlButton(
                symbol: .skipBackward,
                size: 64 * scale,
                symbolSize: 37 * scale,
                animationValue: previousControlAnimationTick,
                action: previousFrame
            )

            loadedControlButton(
                symbol: .system(isPlaying ? "pause.fill" : "play.fill"),
                size: 90 * scale,
                symbolSize: 44 * scale,
                animationValue: playControlAnimationTick,
                action: togglePlayback
            )

            loadedControlButton(
                symbol: .skipForward,
                size: 64 * scale,
                symbolSize: 37 * scale,
                animationValue: nextControlAnimationTick,
                action: nextFrame
            )
        }
    }

    private func loadedControlButton(
        symbol: PlaybackControlSymbol,
        size: CGFloat,
        symbolSize: CGFloat,
        animationValue: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Group {
                switch symbol {
                case .system(let systemName):
                    Image(systemName: systemName)
                case .skipBackward:
                    SkipControlIcon(direction: .backward)
                case .skipForward:
                    SkipControlIcon(direction: .forward)
                }
            }
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: symbolSize, height: symbolSize)
            .frame(width: size, height: size)
            .controlGlassBackground(shape: Circle())
            .symbolEffect(.bounce, value: animationValue)
        }
        .buttonStyle(.plain)
        .disabled(!hasAnimation)
    }

    private func loadedGlassTabBar(width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            loadedGlassTabButton(
                tab: .preview,
                isSelected: true,
                scale: scale
            ) {
                softHaptic()
                loadedTabSelection = .preview
            }

            loadedGlassTabButton(
                tab: .edit,
                isSelected: false,
                scale: scale
            ) {
                handleNativeLoadedTabSelection(.edit)
            }

            loadedGlassTabButton(
                tab: .export,
                isSelected: false,
                scale: scale
            ) {
                handleNativeLoadedTabSelection(.export)
            }
        }
        .padding(5 * scale)
        .frame(width: width, height: height)
        .lightTabGlassBackground(shape: Capsule())
    }

    private func loadedGlassTabButton(
        tab: LoadedActionTab,
        isSelected: Bool,
        scale: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 3 * scale) {
                Image(systemName: tab.systemName)
                    .font(.system(size: 21 * scale, weight: .semibold))

                Text(tab.title)
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color(red: 0.0, green: 0.49, blue: 1.0) : Color(red: 0.02, green: 0.02, blue: 0.10).opacity(0.88))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .selectedTabGlassBackground(isSelected: isSelected, shape: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }

    private func handleNativeLoadedTabSelection(_ tab: LoadedActionTab) {
        switch tab {
        case .preview:
            break
        case .edit:
            softHaptic()
            showingEditSheet = true
        case .export:
            softHaptic()
            showingExportSheet = true
        }
    }

    private var emptyNavigationScreen: some View {
        emptyImportScreen
    }

    private var emptyImportScreen: some View {
        GeometryReader { proxy in
            let bottomInset = proxy.safeAreaInsets.bottom
            let width = proxy.size.width
            let height = proxy.size.height
            let designScale = width / 393
            let compositionLift = height * 0.10
            let cardWidth = min(width - 40, 353 * designScale)
            let buttonHeight = max(52, 52 * designScale)
            let greetingText = emptyGreetings[emptyGreetingIndex]
            let buttonCenterY = height - bottomInset - compositionLift - (34 * designScale)
            let cardHeight = min(225 * designScale, height * 0.33)
            let cardCenterY = buttonCenterY - (buttonHeight / 2) - (18 * designScale) - (cardHeight / 2)
            let logoSize = min(132 * designScale, width * 0.42)
            let logoCenterX = (width / 2) + (10 * designScale)
            let logoCenterY = height / 2
            let greetingCenterY = max(250 * designScale, logoCenterY - (300 * designScale))
            let waveWidth = 511 * designScale
            let waveHeight = 534 * designScale
            let waveCenterX = (-41 + 511 / 2) * designScale
            let waveCenterY = height - (waveHeight / 2) + (44 * designScale) + (height * 0.05)

            ZStack {
                emptyScreenBackground
                    .ignoresSafeArea()

                emptyProfileButton
                    .position(x: width - (38 * designScale), y: 84 * designScale)

                emptyGreetingBubble(text: greetingText, scale: designScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: 38 * designScale, y: greetingCenterY - (74 * designScale))

                Image("EmptyBackgroundWave")
                    .resizable()
                    .scaledToFill()
                    .frame(width: waveWidth, height: waveHeight)
                    .allowsHitTesting(false)
                    .position(x: waveCenterX, y: waveCenterY)

                FlippieBlinkingLogo(size: logoSize)
                    .shadow(color: Color(red: 0.0, green: 0.18, blue: 1.0).opacity(0.22), radius: 22, x: 0, y: 18)
                    .position(x: logoCenterX, y: logoCenterY)

                emptyCopyCard
                    .frame(width: cardWidth, height: cardHeight)
                    .position(x: width / 2, y: cardCenterY)

                emptyImportButton
                    .frame(width: cardWidth, height: buttonHeight)
                    .position(x: width / 2, y: buttonCenterY)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var emptyProfileButton: some View {
        Button {
            softHaptic()
            cycleEmptyGreeting()
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color(red: 0.02, green: 0.02, blue: 0.10))
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
                .liquidGlassBackground(shape: Circle(), cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }

    private var emptyScreenBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.38, blue: 1.0),
                    Color(red: 0.0, green: 0.09, blue: 1.0),
                    Color(red: 0.0, green: 0.05, blue: 0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 34)
                .offset(x: -150, y: -240)

            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 220, height: 220)
                .blur(radius: 42)
                .offset(x: 150, y: 120)
        }
    }

    private func emptyGreetingBubble(text: String, scale: CGFloat) -> some View {
        let fill = Color.white.opacity(0.08)
        let bubbleHeight = 78 * scale
        let horizontalPadding = 24 * scale
        let tailSize = 40 * scale

        return Button {
            softHaptic()
            cycleEmptyGreeting()
        } label: {
            ZStack(alignment: .topLeading) {
                Text(text)
                    .font(.system(size: 31 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, horizontalPadding)
                    .frame(height: bubbleHeight)
                    .background {
                        GeometryReader { proxy in
                            let bubbleWidth = proxy.size.width
                            let tailX = min(42 * scale, bubbleWidth * 0.34)

                            Path { path in
                                path.addRoundedRect(
                                    in: CGRect(
                                        x: 0,
                                        y: 0,
                                        width: bubbleWidth,
                                        height: bubbleHeight
                                    ),
                                    cornerSize: CGSize(width: 34 * scale, height: 34 * scale)
                                )
                                path.addEllipse(
                                    in: CGRect(
                                        x: tailX,
                                        y: bubbleHeight - (tailSize / 2),
                                        width: tailSize,
                                        height: tailSize
                                    )
                                )
                            }
                            .fill(fill)
                        }
                    }

                Circle()
                    .fill(fill)
                    .frame(width: 20 * scale, height: 20 * scale)
                    .offset(x: 56 * scale, y: 108 * scale)

                Circle()
                    .fill(fill)
                    .frame(width: 10 * scale, height: 10 * scale)
                    .offset(x: 71 * scale, y: 138 * scale)
            }
            .frame(height: 148 * scale, alignment: .topLeading)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Greeting")
    }

    private var emptyCopyCard: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 353, proxy.size.height / 225)
            let fill = Color.white.opacity(0.08)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRoundedRect(
                        in: CGRect(
                            x: 0,
                            y: 70 * scale,
                            width: 353 * scale,
                            height: 155 * scale
                        ),
                        cornerSize: CGSize(width: 34 * scale, height: 34 * scale)
                    )
                    path.addEllipse(
                        in: CGRect(
                            x: 243 * scale,
                            y: 50 * scale,
                            width: 40 * scale,
                            height: 40 * scale
                        )
                    )
                }
                .fill(fill)

                Circle()
                    .fill(fill)
                    .frame(width: 20 * scale, height: 20 * scale)
                    .position(x: 254 * scale, y: 30 * scale)

                Circle()
                    .fill(fill)
                    .frame(width: 10 * scale, height: 10 * scale)
                    .position(x: 245 * scale, y: 5 * scale)

                VStack(spacing: 12 * scale) {
                    Text(emptyTitle)
                        .font(.system(size: 32 * scale, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(emptyMessage)
                        .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .multilineTextAlignment(.center)
                        .lineSpacing(1.5 * scale)
                        .lineLimit(5)
                        .minimumScaleFactor(0.74)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            softHaptic()
                            showingBundledAnimations = true
                        }
                }
                .frame(width: 329 * scale, height: 132 * scale)
                .offset(x: 12 * scale, y: 84 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .accessibilityLabel("Choose ready-made lottie")
    }

    private var emptyImportButton: some View {
        Button {
            softHaptic()
            fileImportMode = .animation
            showingFileImporter = true
        } label: {
            Text(isImporting ? "Importing..." : "Import .JSON")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.10))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .liquidGlassBackground(shape: Capsule(), cornerRadius: 26)
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .accessibilityLabel("Import Lottie animation")
    }

    private func cycleEmptyGreeting() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            emptyGreetingIndex = (emptyGreetingIndex + 1) % emptyGreetings.count
        }
    }

    var body: some View {
        ZStack {
            emptyScreenBackground
                .ignoresSafeArea()

            if hasAnimation {
                mainEditorScreen
            } else {
                emptyNavigationScreen
            }
        }
        .background(emptyScreenBackground.ignoresSafeArea())
        .alert("Error", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showingBundledAnimations) {
            BundledAnimationsView { url in
                try loadAnimation(from: url)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: fileImportMode.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
        .sheet(item: $importReport) { report in
            ImportReportSheet(
                report: report,
                metadata: document.metadata,
                diagnostics: document.diagnostics,
                compatibilityResults: importCompatibilityResults,
                isRepairingAssets: isRepairingMissingAssets,
                onLocateAssets: {
                    beginMissingAssetRepair(from: report)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingExportSheet) {
            MainExportView(document: document)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $editingEmptyCopy) {
            EmptyCopyEditorSheet(
                title: $emptyTitle,
                message: $emptyMessage
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEditSheet) {
            EditPropertiesSheet(
                document: document,
                animationSpeed: $animationSpeed,
                totalFrames: $totalFrames,
                onDocumentChanged: {
                    try reloadAnimationFromDocument()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingRendererComparison) {
            if let data = document.renderedData {
                RendererComparisonView(
                    data: data,
                    formatVersion: document.metadata?.formatVersion
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingPlaybackSettingsDialog) {
            PlaybackSettingsSheet(
                selectedRuntime: runtimeSelection,
                isSwitchingRuntime: isSwitchingRuntime,
                canTestRenderers: document.selectedRuntime == .v461
                    && document.renderedData.map(AnimationDocument.requiresWebRenderer) != true,
                animationSpeed: Binding(
                    get: { animationSpeed },
                    set: { setSpeed($0) }
                ),
                loopMode: Binding(
                    get: { loopMode },
                    set: { setLoopMode($0) }
                ),
                onTestRenderers: {
                    softHaptic()
                    showingPlaybackSettingsDialog = false
                    showingRendererComparison = true
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-loadSampleOnLaunch"), !hasAnimation {
                loadFirstSampleAnimation()
            }
            #endif
        }
        .onDisappear {
            progressTimer?.invalidate()
        }
    }
    
    // MARK: - Animation Loading
    private func loadAnimation(from url: URL) throws {
        statusMessage = "Loading animation..."

        let data = try Data(contentsOf: url)
        try loadAnimation(data: data, sourceURL: url)
        statusMessage = ""
    }

    private func loadAnimation(data: Data, sourceURL: URL) throws {
        try LottieImportService.validate(data)

        let candidate = AnimationDocument()
        try candidate.load(data: data, sourceURL: sourceURL)
        guard let candidateData = candidate.renderedData else {
            throw AnimationDocumentError.invalidRootObject
        }
        try configurePlayer(
            with: candidateData,
            runtime: .embedded,
            baseURL: sourceURL.deletingLastPathComponent(),
            preservingProgress: false
        )

        try document.load(data: data, sourceURL: sourceURL)
        animationSpeed = document.edits.playbackSpeed
        animationView.animationSpeed = animationSpeed
        runtimeStatusMessage = document.hasRenderingLimitations
            ? "Gaussian Blur rendered with lottie-web"
            : "Loaded with \(document.selectedRuntime.title)"
    }

    private func reloadAnimationFromDocument() throws {
        animationSpeed = document.edits.playbackSpeed
        try configurePlayer(
            with: document.renderedData,
            runtime: document.selectedRuntime,
            baseURL: document.sourceURL?.deletingLastPathComponent(),
            preservingProgress: true
        )
    }

    private func configurePlayer(
        with data: Data?,
        runtime: LottieRuntimeVersion,
        baseURL: URL? = nil,
        preservingProgress: Bool = false
    ) throws {
        guard let data else {
            throw AnimationDocumentError.invalidRootObject
        }

        let previousProgress = preservingProgress ? animationView.currentProgress : 0
        let wasPlaying = preservingProgress && isPlaying

        animationView.stop()
        progressTimer?.invalidate()
        let frameRange = try animationView.load(
            data: data,
            runtime: runtime,
            baseURL: baseURL
        )
        animationView.loopMode = loopMode
        animationView.animationSpeed = animationSpeed
        animationView.backgroundColor = .clear

        animationStartFrame = frameRange.start
        animationEndFrame = frameRange.end
        totalFrames = animationEndFrame - animationStartFrame
        currentFrame = preservingProgress ? previousProgress * totalFrames : 0
        hasAnimation = true
        isPlaying = wasPlaying
        animationView.currentProgress = previousProgress

        if wasPlaying {
            animationView.play()
            startProgressTracking()
        }
    }

    private func switchRuntime(to runtime: LottieRuntimeVersion) {
        guard document.isLoaded,
              runtime != document.selectedRuntime,
              !isSwitchingRuntime else { return }

        let previousRuntime = document.selectedRuntime
        let wasPlaying = isPlaying
        isSwitchingRuntime = true
        pendingRuntime = runtime
        runtimeStatusMessage = ""

        Task { @MainActor in
            await Task.yield()
            defer {
                isSwitchingRuntime = false
                pendingRuntime = nil
            }

            do {
                try configurePlayer(
                    with: document.renderedData,
                    runtime: runtime,
                    baseURL: document.sourceURL?.deletingLastPathComponent(),
                    preservingProgress: true
                )
                document.selectRuntime(runtime)
                runtimeStatusMessage = document.hasRenderingLimitations
                    ? "Gaussian Blur uses the shared lottie-web renderer"
                    : "Rendered successfully with \(runtime.title)"
            } catch {
                if wasPlaying {
                    animationView.play()
                    startProgressTracking()
                    isPlaying = true
                }
                alertMessage = "\(runtime.title) could not render this animation. \(previousRuntime.title) remains active.\n\n\(error.localizedDescription)"
                showingAlert = true
            }
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch fileImportMode {
        case .animation:
            handleImportResult(result)
        case .assetRepair:
            handleAssetRepairResult(result)
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importAnimation(from: url)
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            alertMessage = "File selection failed: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func handleAssetRepairResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first,
                  let report = pendingAssetRepairReport else { return }
            repairMissingAssets(in: report, from: url)
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError {
                importReport = pendingAssetRepairReport
                pendingAssetRepairReport = nil
                return
            }
            pendingAssetRepairReport = nil
            alertMessage = "Asset folder selection failed: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func importAnimation(from url: URL) {
        isImporting = true
        statusMessage = "Reading and validating \(url.lastPathComponent)…"

        Task { @MainActor in
            defer { isImporting = false }
            var packageURL: URL?
            do {
                let imported = try await LottieImportService.importAnimation(from: url)
                packageURL = imported.packageURL
                try loadAnimation(data: imported.data, sourceURL: imported.url)
                statusMessage = "Testing runtime compatibility…"
                importCompatibilityResults = makeCompatibilityMatrix(
                    data: document.renderedData ?? imported.data,
                    baseURL: imported.url.deletingLastPathComponent()
                )
                importReport = imported.report
                statusMessage = ""
            } catch {
                if let packageURL {
                    try? FileManager.default.removeItem(at: packageURL)
                }
                statusMessage = ""
                alertMessage = "Import failed: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }

    private func beginMissingAssetRepair(from report: LottieImportReport) {
        softHaptic()
        pendingAssetRepairReport = report
        importReport = nil

        Task { @MainActor in
            await Task.yield()
            fileImportMode = .assetRepair
            showingFileImporter = true
        }
    }

    private func repairMissingAssets(
        in report: LottieImportReport,
        from searchDirectory: URL
    ) {
        isRepairingMissingAssets = true
        statusMessage = "Locating missing assets…"

        Task { @MainActor in
            defer {
                isRepairingMissingAssets = false
                pendingAssetRepairReport = nil
            }

            do {
                let repairedReport = try await LottieImportService.repairMissingAssets(
                    in: report,
                    from: searchDirectory
                )
                let data = try Data(contentsOf: repairedReport.animationURL)
                try loadAnimation(data: data, sourceURL: repairedReport.animationURL)
                importCompatibilityResults = makeCompatibilityMatrix(
                    data: document.renderedData ?? data,
                    baseURL: repairedReport.animationURL.deletingLastPathComponent()
                )
                importReport = repairedReport
                statusMessage = ""
            } catch {
                statusMessage = ""
                importReport = report
                alertMessage = "Asset repair failed: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }

    private func makeCompatibilityMatrix(
        data: Data,
        baseURL: URL?
    ) -> [LottieCompatibilityResult] {
        LottieRuntimeVersion.allCases.map { runtime in
            let player = VersionedLottiePlayerView()
            do {
                let range = try player.load(
                    data: data,
                    runtime: runtime,
                    baseURL: baseURL
                )
                player.stop()

                if player.usesWebRenderer {
                    return LottieCompatibilityResult(
                        runtime: runtime,
                        status: .fallback,
                        rendererName: player.currentRenderingEngineName,
                        frameRangeDescription: frameRangeDescription(range),
                        message: "Native \(runtime.shortTitle) was bypassed because this animation needs the shared web fallback."
                    )
                }

                return LottieCompatibilityResult(
                    runtime: runtime,
                    status: .passed,
                    rendererName: player.currentRenderingEngineName,
                    frameRangeDescription: frameRangeDescription(range),
                    message: "Loaded by \(runtime.title)."
                )
            } catch {
                return LottieCompatibilityResult(
                    runtime: runtime,
                    status: .failed,
                    rendererName: "Not loaded",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func frameRangeDescription(_ range: AnimationFrameRange) -> String {
        "\(Int(range.start))–\(Int(range.end)) frames · \(String(format: "%.2fs", range.duration))"
    }

    private func closeCurrentAnimation() {
        animationView.stop()
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
        currentFrame = 0
        hasAnimation = false
        statusMessage = ""
        runtimeStatusMessage = ""
        importReport = nil
        pendingAssetRepairReport = nil
        importCompatibilityResults = []
        isSwitchingRuntime = false
        pendingRuntime = nil
    }

    // MARK: - Playback Controls
    private func togglePlayback() {
        print("🎮 ContentView: Toggle playback - currently playing: \(isPlaying)")
        guard hasAnimation else { 
            print("❌ ContentView: No animation loaded for playback")
            return 
        }
        playControlAnimationTick += 1
        softHaptic()
        
        if isPlaying {
            print("🎮 ContentView: Pausing animation")
            animationView.pause()
            progressTimer?.invalidate()
        } else {
            print("🎮 ContentView: Playing animation")
            animationView.play()
            startProgressTracking()
        }
        isPlaying.toggle()
        print("🎮 ContentView: Playback state now: \(isPlaying)")
    }
    
    private func previousFrame() {
        guard hasAnimation else { return }
        previousControlAnimationTick += 1
        softHaptic()
        let newUserFrame = max(0, currentFrame - 1)
        currentFrame = newUserFrame
        let animationFrame = userFrameToAnimationFrame(newUserFrame)
        animationView.currentFrame = animationFrame
        print("🎮 Previous: User frame \(Int(newUserFrame)) → Animation frame \(Int(animationFrame))")
    }
    
    private func nextFrame() {
        guard hasAnimation else { return }
        nextControlAnimationTick += 1
        softHaptic()
        let newUserFrame = min(totalFrames, currentFrame + 1)
        currentFrame = newUserFrame
        let animationFrame = userFrameToAnimationFrame(newUserFrame)
        animationView.currentFrame = animationFrame
        print("🎮 Next: User frame \(Int(newUserFrame)) → Animation frame \(Int(animationFrame))")
    }
    
    private func seekToFrame(_ frame: Double) {
        guard hasAnimation else { return }
        let animationFrame = userFrameToAnimationFrame(frame)
        animationView.currentFrame = animationFrame
        print("🎮 Seek: User frame \(Int(frame)) → Animation frame \(Int(animationFrame))")
    }
    
    private func setSpeed(_ speed: Double) {
        softHaptic()
        print("⚡ ContentView: Setting speed to \(speed)x")
        animationSpeed = speed
        document.updatePlaybackSpeed(speed)
        if hasAnimation {
            animationView.animationSpeed = speed
            print("⚡ ContentView: Speed applied to animationView")
        } else {
            print("❌ ContentView: No animation loaded to apply speed to")
        }
    }
    
    private func setLoopMode(_ mode: PlayerLoopMode) {
        softHaptic()
        print("🔄 ContentView: Setting loop mode to \(mode)")
        loopMode = mode
        if hasAnimation {
            animationView.loopMode = mode
            print("🔄 ContentView: Loop mode applied to animationView")
        } else {
            print("❌ ContentView: No animation loaded to apply loop mode to")
        }
    }
    
    private func loopModeText(_ mode: PlayerLoopMode) -> String {
        switch mode {
        case .playOnce:
            return "Once"
        case .loop:
            return "Loop"
        case .autoReverse:
            return "Ping-Pong"
        }
    }
    
    private func loopModeIcon(_ mode: PlayerLoopMode) -> String {
        switch mode {
        case .playOnce:
            return "play"
        case .loop:
            return "arrow.clockwise"
        case .autoReverse:
            return "arrow.left.arrow.right"
        }
    }
    
    private func startProgressTracking() {
        print("📊 ContentView: Starting progress tracking")
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if hasAnimation {
                    let animationFrame = animationView.currentFrame
                    let userFrame = animationFrameToUserFrame(animationFrame)
                    
                    if userFrame != currentFrame {
                        currentFrame = max(0, min(totalFrames, userFrame))

                        if Int(userFrame) % 30 == 0 {
                            print("📊 Progress: Animation frame \(Int(animationFrame)) → User frame \(Int(userFrame))/\(Int(totalFrames))")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Test Helper
    private func loadFirstSampleAnimation() {
        print("🧪 ContentView: Auto-loading first sample animation for testing")
        print("🧪 ContentView: Bundle path: \(Bundle.main.bundlePath)")
        
        // Try to load the first available sample animation
        let sampleAnimations = [
            "note_outline_music_sa_outline_to_fill_28.json",
            "compass_music_sa_outline_to_fill_28 2.json",
            "heart_list_music_sa_outline_to_fill_28.json",
            "horse_toy_outline_music_sa_outline_to_fill_28.json",
            "podcast_books_outline_music_sa_outline_to_fill_28.json",
            "radio_outline_music_sa_outline_to_fill_28.json"
        ]
        
        for animationName in sampleAnimations {
            // Try with exact name first
            if let url = Bundle.main.url(forResource: animationName, withExtension: nil) {
                print("🧪 ContentView: Found sample animation: \(animationName)")
                try? loadAnimation(from: url)
                return
            }
            
            // Try without extension
            let nameWithoutExtension = animationName.replacingOccurrences(of: ".json", with: "")
            if let url = Bundle.main.url(forResource: nameWithoutExtension, withExtension: "json") {
                print("🧪 ContentView: Found sample animation: \(nameWithoutExtension).json")
                try? loadAnimation(from: url)
                return
            }
        }
        
        print("🧪 ContentView: No sample animations found in bundle")
    }
    
    // MARK: - Frame Mapping Helper Functions
    private func userFrameToAnimationFrame(_ userFrame: Double) -> Double {
        return animationStartFrame + userFrame
    }
    
    private func animationFrameToUserFrame(_ animationFrame: Double) -> Double {
        return animationFrame - animationStartFrame
    }
}

private struct ImportReportSheet: View {
    let report: LottieImportReport
    let metadata: AnimationMetadata?
    let diagnostics: [AnimationDiagnostic]
    let compatibilityResults: [LottieCompatibilityResult]
    let isRepairingAssets: Bool
    let onLocateAssets: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summarySection
                    animationSection
                    assetSection
                    compatibilitySection
                    rendererSection
                }
                .padding(20)
            }
            .navigationTitle("Import report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(hasWarnings ? .orange : .green)

                VStack(alignment: .leading, spacing: 3) {
                    Text(hasWarnings ? "Imported with warnings" : "Imported successfully")
                        .font(.headline)
                    Text("\(report.kind.rawValue) · \(report.sourceFileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricCard("Package", "\(report.packageFileCount) files")
                metricCard("Size", byteString(report.packageSizeBytes))
                metricCard("Images", "\(report.imageAssets.count)")
                metricCard("Missing", "\(report.missingExternalImageCount + report.unsupportedRemoteImageCount)")
                metricCard("Runtimes", runtimeMetric)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var animationSection: some View {
        reportSection("Animation") {
            reportRow("Format", metadata?.formatVersion ?? "Unknown", systemImage: "doc.text")
            if let metadata {
                reportRow("Canvas", "\(metadata.width) × \(metadata.height)", systemImage: "rectangle")
                reportRow(
                    "Timeline",
                    "\(Int(metadata.frameCount)) frames · \(String(format: "%.0f", metadata.frameRate)) fps",
                    systemImage: "timeline.selection"
                )
                reportRow("Layers", "\(metadata.layerCount) root / \(metadata.features.totalLayerCount) total", systemImage: "square.stack.3d.up")
                reportRow("Assets", metadata.features.assetSummary, systemImage: "photo.on.rectangle")
            }
            if let selectedAnimationPath = report.selectedAnimationPath {
                reportRow("Selected", selectedAnimationPath, systemImage: "scope")
            }
            if report.manifestURL != nil {
                reportRow("Manifest", "Found", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private var assetSection: some View {
        reportSection("Assets") {
            if report.missingExternalImageCount > 0 {
                Button {
                    onLocateAssets()
                } label: {
                    Label(
                        isRepairingAssets ? "Searching…" : "Locate missing assets",
                        systemImage: "folder.badge.questionmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRepairingAssets)
            }

            if report.imageAssets.isEmpty {
                reportRow("Images", "No image assets declared", systemImage: "photo")
            } else {
                ForEach(report.imageAssets) { asset in
                    assetRow(asset)
                }
            }
        }
    }

    private var compatibilitySection: some View {
        reportSection("Runtime matrix") {
            if compatibilityResults.isEmpty {
                reportRow("Status", "Runtime compatibility has not been tested yet.", systemImage: "clock")
            } else {
                ForEach(compatibilityResults) { result in
                    compatibilityRow(result)
                }
            }
        }
    }

    private var rendererSection: some View {
        reportSection("Renderer notes") {
            if diagnostics.isEmpty {
                reportRow("Compatibility", "No warnings detected", systemImage: "checkmark.seal")
            } else {
                ForEach(diagnostics.prefix(8)) { diagnostic in
                    reportRow(
                        diagnosticTitle(diagnostic),
                        diagnostic.message,
                        systemImage: diagnosticIcon(diagnostic.severity),
                        color: diagnosticColor(diagnostic.severity)
                    )
                }
                if diagnostics.count > 8 {
                    reportRow("More", "\(diagnostics.count - 8) more note(s) in Edit", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var hasWarnings: Bool {
        report.hasAssetProblems
            || compatibilityResults.contains { $0.status != .passed }
            || diagnostics.contains { $0.severity == .warning || $0.severity == .error }
    }

    private var runtimeMetric: String {
        guard !compatibilityResults.isEmpty else { return "Not tested" }
        let passed = compatibilityResults.filter { $0.status == .passed }.count
        let fallback = compatibilityResults.filter { $0.status == .fallback }.count
        let failed = compatibilityResults.filter { $0.status == .failed }.count
        if failed > 0 {
            return "\(passed) ok · \(failed) fail"
        }
        if fallback > 0 {
            return "\(fallback) fallback"
        }
        return "\(passed)/\(compatibilityResults.count) ok"
    }

    private func reportSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(spacing: 10) {
                content()
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func metricCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func assetRow(_ asset: LottieImportAssetReport) -> some View {
        let color = assetColor(asset.status)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: assetIcon(asset.status))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(asset.assetID ?? "Image")
                        .font(.subheadline.weight(.semibold))
                    Text(assetStatusTitle(asset.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                }

                Text(asset.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let resolvedURL = asset.resolvedURL {
                    Text(relativeDisplayPath(resolvedURL, in: report.packageURL))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !asset.candidatePaths.isEmpty {
                    Text("Checked: \(asset.candidatePaths.prefix(3).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if asset.copiedFromURL != nil {
                    Text("Copied into import package")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            Spacer()
        }
    }

    private func compatibilityRow(_ result: LottieCompatibilityResult) -> some View {
        let color = compatibilityColor(result.status)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: compatibilityIcon(result.status))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(result.runtime.title)
                        .font(.subheadline.weight(.semibold))
                    Text(compatibilityTitle(result.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                }

                Text(result.rendererName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let frameRangeDescription = result.frameRangeDescription {
                    Text(frameRangeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let message = result.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(result.status == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
    }

    private func reportRow(
        _ title: String,
        _ value: String,
        systemImage: String,
        color: Color = .blue
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(bytes),
            countStyle: .file
        )
    }

    private func relativeDisplayPath(_ url: URL, in directoryURL: URL) -> String {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(directoryPath) else {
            return url.lastPathComponent
        }
        return filePath
            .dropFirst(directoryPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func assetStatusTitle(_ status: LottieImportAssetReport.Status) -> String {
        switch status {
        case .embedded: "Embedded"
        case .resolved: "Found"
        case .missing: "Missing"
        case .remoteUnsupported: "Remote URL"
        }
    }

    private func assetIcon(_ status: LottieImportAssetReport.Status) -> String {
        switch status {
        case .embedded: "shippingbox.fill"
        case .resolved: "checkmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .remoteUnsupported: "network.slash"
        }
    }

    private func assetColor(_ status: LottieImportAssetReport.Status) -> Color {
        switch status {
        case .embedded, .resolved: .green
        case .missing, .remoteUnsupported: .orange
        }
    }

    private func compatibilityTitle(_ status: LottieCompatibilityResult.Status) -> String {
        switch status {
        case .passed: "Pass"
        case .fallback: "Fallback"
        case .failed: "Failed"
        }
    }

    private func compatibilityIcon(_ status: LottieCompatibilityResult.Status) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .fallback: "arrow.triangle.2.circlepath.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func compatibilityColor(_ status: LottieCompatibilityResult.Status) -> Color {
        switch status {
        case .passed: .green
        case .fallback: .orange
        case .failed: .red
        }
    }

    private func diagnosticTitle(_ diagnostic: AnimationDiagnostic) -> String {
        diagnostic.id
            .replacingOccurrences(of: "render-", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private func diagnosticIcon(_ severity: AnimationDiagnostic.Severity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func diagnosticColor(_ severity: AnimationDiagnostic.Severity) -> Color {
        switch severity {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct EmptyCopyEditorSheet: View {
    @Binding var title: String
    @Binding var message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }

                Section("Message") {
                    TextEditor(text: $message)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("Empty State Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        softHaptic()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PlaybackSettingsSheet: View {
    @Binding var selectedRuntime: LottieRuntimeVersion
    let isSwitchingRuntime: Bool
    let canTestRenderers: Bool
    @Binding var animationSpeed: Double
    @Binding var loopMode: PlayerLoopMode
    let onTestRenderers: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Speed") {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                        Button {
                            animationSpeed = speed
                        } label: {
                            SettingsCheckRow(
                                title: speed == 1.0 ? "1x" : "\(speed.formatted(.number.precision(.fractionLength(1))))x",
                                isSelected: animationSpeed == speed
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Loop") {
                    ForEach(PlayerLoopMode.allCases, id: \.self) { mode in
                        Button {
                            loopMode = mode
                        } label: {
                            SettingsCheckRow(
                                title: mode.settingsTitle,
                                systemImage: mode.settingsSystemImage,
                                isSelected: loopMode == mode
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Lottie Runtime") {
                    ForEach(LottieRuntimeVersion.allCases) { runtime in
                        Button {
                            selectedRuntime = runtime
                        } label: {
                            SettingsCheckRow(
                                title: runtime.shortTitle,
                                isSelected: selectedRuntime == runtime
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSwitchingRuntime)
                    }
                }

                Section("Testing") {
                    Button("Test Renderers") {
                        onTestRenderers()
                    }
                    .disabled(!canTestRenderers)
                }
            }
            .navigationTitle("Playback Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SettingsCheckRow: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .foregroundStyle(.primary)

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
    }
}

private extension PlayerLoopMode {
    var settingsTitle: String {
        switch self {
        case .playOnce:
            return "Play Once"
        case .loop:
            return "Loop"
        case .autoReverse:
            return "Back-and-Forth"
        }
    }

    var settingsSystemImage: String {
        switch self {
        case .playOnce:
            return "play"
        case .loop:
            return "arrow.clockwise"
        case .autoReverse:
            return "arrow.left.arrow.right"
        }
    }
}

private struct CheckerboardView: View {
    let squareSize: CGFloat

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.96, green: 0.96, blue: 0.96))
            )

            let square = max(4, squareSize)
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            let alternate = Color(red: 0.90, green: 0.90, blue: 0.90)

            for row in 0...rows {
                for column in 0...columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * square,
                        y: CGFloat(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(alternate))
                }
            }
        }
    }
}

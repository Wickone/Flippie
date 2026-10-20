import SwiftUI
import UIKit

private func softHaptic() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.75)
}

struct ContentView: View {
    @StateObject private var document: AnimationDocument
    @StateObject private var session: PlaybackSession
    @StateObject private var sheets: SheetCoordinator
    @StateObject private var persistence: ProjectPersistenceCoordinator
    private let persistenceEnabled: Bool
    @State private var didPrepareLaunch = false
    @State private var launchTask: Task<Void, Never>?
    @State private var canRecoverSavedProject = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var showingProfileInfo = false
    @State private var showingFileImporter = false
    @State private var fileImportMode: FileImportMode = .animation
    @State private var showingAlert = false
    @State private var showAssetPickerAfterDismiss = false
    @State private var pendingPackageCleanupURL: URL?
    @State private var pendingAnimationSelection: (file: ImportedLottieFile, path: String)?
    @State private var pendingAssetRepairReport: LottieImportReport?
    @State private var importCompatibilityResults: [LottieCompatibilityResult] = []
    @State private var alertMessage = ""
    @State private var statusMessage = ""
    @State private var isImporting = false
    @State private var isRepairingMissingAssets = false
    @State private var runtimeStatusMessage = ""
    @State private var emptyGreetingIndex = 0
    @State private var emptyTitle = "Import lottie"
    @State private var emptyMessage = "Welcome to your flippie! Tap this text to choose a ready-made lottie, see how it fits your flippie, and add it when you’re ready."
    @State private var previousControlAnimationTick = 0
    @State private var playControlAnimationTick = 0
    @State private var nextControlAnimationTick = 0
    
    init(document: AnimationDocument? = nil, session: PlaybackSession? = nil, sheets: SheetCoordinator? = nil,
         persistence: ProjectPersistenceCoordinator? = nil) {
        _document = StateObject(wrappedValue: document ?? AnimationDocument())
        _session = StateObject(wrappedValue: session ?? PlaybackSession())
        _sheets = StateObject(wrappedValue: sheets ?? SheetCoordinator())
        _persistence = StateObject(wrappedValue: persistence ?? ProjectPersistenceCoordinator())
        #if DEBUG
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        #else
        let uiTesting = false
        #endif
        persistenceEnabled = !uiTesting && (persistence != nil || (document == nil && session == nil))
    }

    private var animationView: VersionedLottiePlayerView { session.player }
    private var hasAnimation: Bool { session.hasAnimation }
    private var isPlaying: Bool { session.isPlaying }
    private var currentFrame: Double { session.currentFrame }
    private var totalFrames: Double { session.totalFrames }
    private var animationSpeed: Double { session.speed }
    private var loopMode: PlayerLoopMode { session.loopMode }
    private var pendingRuntime: LottieRuntimeVersion? { session.pendingRuntime }
    private var isSwitchingRuntime: Bool { session.pendingRuntime != nil }

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
            sheets.present(.edit)
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
            Slider(value: Binding(get: { currentFrame }, set: { seekToFrame($0) }), in: 0...max(1, totalFrames)) { editing in
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
                    sheets.present(.rendererComparison)
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

    private var loadedEditorScreen: some View {
        NativePreviewTabs(onCommand: handleNativeLoadedTabSelection) {
            LoadedPreviewScreen(document: document, session: session,
                reservedBottomSpace: NativePreviewPlacement.lift(for: UIDevice.current.userInterfaceIdiom),
                onBack: { softHaptic(); closeCurrentAnimation() },
                onProfile: showProfile,
                onSettings: { softHaptic(); sheets.present(.playbackSettings) },
                onPlay: togglePlayback, onPrevious: previousFrame, onNext: nextFrame)
        }
        .ignoresSafeArea()
    }

    private func handleNativeLoadedTabSelection(_ tab: LoadedActionTab) {
        switch tab {
        case .preview: break
        case .edit: softHaptic(); sheets.present(.edit)
        case .export: softHaptic(); sheets.present(.export)
        }
    }

    private var emptyNavigationScreen: some View {
        emptyImportScreen
    }

    private var emptyImportScreen: some View {
        NavigationStack {
            GeometryReader { proxy in
                if !dynamicType.isAccessibilitySize && proxy.size.width < 600 && proxy.size.height > proxy.size.width {
                    emptyPortraitContent(in: proxy)
                } else {
                    adaptiveEmptyContent
                }
            }
            .background(emptyScreenBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Profile", systemImage: "person.crop.circle", action: showProfile)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 28, weight: .medium))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .coordinateSpace(name: "landing-layout")
        .tint(.primary)
    }

    private func emptyPortraitContent(in proxy: GeometryProxy) -> some View {
        let width = proxy.size.width
        let topInset = proxy.frame(in: .named("landing-layout")).minY
        let height = proxy.size.height + topInset + proxy.safeAreaInsets.bottom
        let scale = max(1, width) / 393
        let cardWidth = max(0, width - 40)
        let buttonHeight = max(52, 52 * scale)
        let buttonCenterY = height * 0.9 - 34 * scale
        let cardHeight = min(225 * scale, height * 0.33)
        let cardCenterY = buttonCenterY - buttonHeight / 2 - 18 * scale - cardHeight / 2
        return ZStack {
            emptyGreetingBubble(text: emptyGreetings[emptyGreetingIndex], scale: scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: 38 * scale, y: max(250 * scale, height / 2 - 300 * scale) - 74 * scale - topInset)
            Image("EmptyBackgroundWave")
                .resizable().scaledToFill()
                .frame(width: 511 * scale, height: 534 * scale)
                .position(x: (-41 + 511 / 2) * scale,
                          y: height * 1.05 - 223 * scale - topInset)
                .allowsHitTesting(false).accessibilityHidden(true)
            FlippieBlinkingLogo(size: min(132 * scale, width * 0.42))
                .shadow(color: Color(red: 0, green: 0.18, blue: 1).opacity(0.22), radius: 22, x: 0, y: 18)
                .position(x: width / 2 + 10 * scale, y: height / 2 - topInset)
                .accessibilityHidden(true)
            emptyPortraitCopyCard(scale: cardHeight / 225)
                .frame(width: cardWidth, height: cardHeight)
                .position(x: width / 2, y: cardCenterY - topInset)
            emptyImportButton(height: buttonHeight)
                .frame(width: cardWidth, height: buttonHeight)
                .position(x: width / 2, y: buttonCenterY - topInset)
        }
        .frame(width: width, height: proxy.size.height)
    }

    private func emptyGreetingBubble(text: String, scale: CGFloat) -> some View {
        Button {
            softHaptic()
            cycleEmptyGreeting()
        } label: {
            ZStack(alignment: .topLeading) {
                Text(text)
                    .font(.system(size: 31 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 24 * scale)
                    .frame(height: 78 * scale)
                    .background {
                        GeometryReader { bubble in
                            Path { path in
                                path.addRoundedRect(in: CGRect(x: 0, y: 0, width: bubble.size.width, height: 78 * scale),
                                                    cornerSize: CGSize(width: 34 * scale, height: 34 * scale))
                                path.addEllipse(in: CGRect(x: min(42 * scale, bubble.size.width * 0.34),
                                                           y: 58 * scale, width: 40 * scale, height: 40 * scale))
                            }
                            .fill(.white.opacity(0.08))
                        }
                    }
                Circle().fill(.white.opacity(0.08)).frame(width: 20 * scale, height: 20 * scale)
                    .offset(x: 56 * scale, y: 108 * scale)
                Circle().fill(.white.opacity(0.08)).frame(width: 10 * scale, height: 10 * scale)
                    .offset(x: 71 * scale, y: 138 * scale)
            }
            .frame(height: 148 * scale, alignment: .topLeading)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Greeting")
    }

    private func emptyPortraitCopyCard(scale: CGFloat) -> some View {
        Button {
            softHaptic()
            sheets.present(.bundledAnimations)
        } label: {
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRoundedRect(in: CGRect(x: 0, y: 70 * scale, width: 353 * scale, height: 155 * scale),
                                        cornerSize: CGSize(width: 34 * scale, height: 34 * scale))
                    path.addEllipse(in: CGRect(x: 243 * scale, y: 50 * scale, width: 40 * scale, height: 40 * scale))
                }
                .fill(.white.opacity(0.08))
                Circle().fill(.white.opacity(0.08)).frame(width: 20 * scale, height: 20 * scale)
                    .position(x: 254 * scale, y: 30 * scale)
                Circle().fill(.white.opacity(0.08)).frame(width: 10 * scale, height: 10 * scale)
                    .position(x: 245 * scale, y: 5 * scale)
                VStack(spacing: 12 * scale) {
                    Text(emptyTitle).font(.system(size: 32 * scale, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.72)
                    Text(emptyMessage).font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52)).multilineTextAlignment(.center)
                        .lineSpacing(1.5 * scale).lineLimit(5).minimumScaleFactor(0.74)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 329 * scale, height: 132 * scale)
                .offset(x: 12 * scale, y: 84 * scale)
            }
            .frame(width: 353 * scale, height: 225 * scale, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("choose-bundled-animation")
    }

    private var adaptiveEmptyContent: some View {
            ScrollView {
                VStack(spacing: 24) {
                    Button(emptyGreetings[emptyGreetingIndex]) {
                        softHaptic()
                        cycleEmptyGreeting()
                    }
                    .font(.system(.title, design: .rounded, weight: .black))
                    .foregroundStyle(.white)
                    .padding(20)
                    .background(.white.opacity(0.08), in: Capsule())

                    FlippieBlinkingLogo(size: 132)
                        .accessibilityHidden(true)
                        .padding(.vertical, 12)

                    Button {
                        softHaptic()
                        sheets.present(.bundledAnimations)
                    } label: {
                        VStack(spacing: 12) {
                            Text(emptyTitle)
                                .font(.system(.title, design: .rounded, weight: .heavy))
                            Text(emptyMessage).font(.body)
                        }
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 32))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("choose-bundled-animation")

                    emptyImportButton()
                }
                .frame(maxWidth: 560)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(alignment: .bottom) {
                Image("EmptyBackgroundWave").resizable().scaledToFit()
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }

    private func showProfile() {
        softHaptic()
        showingProfileInfo = true
    }

    private var emptyScreenBackground: some View { FlippieScreenBackground() }



    private func emptyImportButton(height: CGFloat? = nil) -> some View {
        Button {
            softHaptic()
            fileImportMode = .animation
            showingFileImporter = true
        } label: {
            Text(isImporting ? "Importing..." : "Import .JSON")
                .font(dynamicType.isAccessibilitySize ? .system(.title2, design: .rounded, weight: .black)
                      : .system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.10))
                .frame(maxWidth: .infinity)
                .padding(.vertical, height == nil ? 12 : 0)
                .frame(minHeight: height ?? 52)
                .frame(height: height)
                .liquidGlassBackground(shape: Capsule(), cornerRadius: 26)
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .accessibilityLabel("Import Lottie animation")
        .accessibilityIdentifier("import-animation")
    }

    private func cycleEmptyGreeting() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
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
        .alert("Profile", isPresented: $showingProfileInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Profiles are coming soon. Your projects are stored on this device.")
        }
        .alert("Error", isPresented: $showingAlert) {
            Button("OK") { }
            if canRecoverSavedProject {
                Button("Keep damaged copy and start fresh") {
                    Task { @MainActor in
                        do {
                            _ = try await persistence.recoverDamagedProject(document: document)
                            canRecoverSavedProject = false
                            if document.isLoaded { try await persistence.save(document) }
                        } catch { showProjectSaveError(error) }
                    }
                }
            }
        } message: {
            Text(alertMessage)
        }
        .sheet(item: Binding(get: { sheets.active }, set: { if $0 == nil { sheets.dismiss() } }), onDismiss: sheetDidDismiss) { route in
            sheetContent(for: route)
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
        .onAppear {
            session.setSceneActive(scenePhase == .active)
            prepareLaunchIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            session.setSceneActive(phase == .active)
            if phase == .background { scheduleProjectSave(protectInBackground: true) }
        }
    }

    @ViewBuilder
    private func sheetContent(for route: SheetRoute) -> some View {
        switch route {
        case .bundledAnimations:
            BundledAnimationsView { url in
                try await loadAnimation(from: url)
            }
        case .importReport(let report):
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
        case .animationPicker(let imported):
            LottieAnimationPickerSheet(
                animations: imported.report.animations,
                selectedPath: imported.report.selectedAnimationPath,
                onSelect: { path in
                    pendingAnimationSelection = (imported, path)
                    sheets.dismiss()
                },
                onCancel: { sheets.dismiss() }
            )
        case .export:
            MainExportView(document: document)
        case .emptyCopy:
            EmptyCopyEditorSheet(
                title: $emptyTitle,
                message: $emptyMessage
            )
        case .edit:
            EditPropertiesSheet(
                document: document,
                animationSpeed: $session.speed,
                totalFrames: totalFrames,
                onDocumentChanged: {
                    try await reloadAnimationFromDocument()
                    if persistenceEnabled { try await persistence.save(document, allowPendingEdits: true) }
                },
                onSaveProject: persistenceEnabled ? { try await persistence.save(document) } : nil
            )
        case .rendererComparison:
            if let data = document.renderedData {
                RendererComparisonView(
                    data: data,
                    formatVersion: document.metadata?.formatVersion,
                    baseURL: document.assetBaseURL
                )
            }
        case .playbackSettings:
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
                    sheets.present(.rendererComparison)
                }
            )
        }
    }

    private func sheetDidDismiss() {
        let dismissed = sheets.didDismiss()
        if case .animationPicker = dismissed { discardPendingPackage() }
        if showAssetPickerAfterDismiss {
            showAssetPickerAfterDismiss = false
            fileImportMode = .assetRepair
            showingFileImporter = true
        }
    }
    
    // MARK: - Animation Loading
    private func prepareLaunchIfNeeded() {
        guard !didPrepareLaunch else { return }
        didPrepareLaunch = true
        // A normal launch always starts at Home. Keep the saved project intact;
        // saving a project does not authorize automatically opening it.
        launchTask = Task { @MainActor in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-loadSampleOnLaunch"), !hasAnimation,
               !Task.isCancelled { loadFirstSampleAnimation() }
            #endif
        }
    }

    private func scheduleProjectSave(protectInBackground: Bool = false) {
        guard persistenceEnabled, document.isLoaded, !document.isApplyingEdits, !persistence.isRecovering else { return }
        do {
            let save = try persistence.enqueue(document)
            let background = protectInBackground
                ? UIApplication.shared.beginBackgroundTask(withName: "Save Flippie project", expirationHandler: { save.cancel() })
                : UIBackgroundTaskIdentifier.invalid
            Task { @MainActor in
                defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                do { try await save.value }
                catch is CancellationError { }
                catch { showProjectSaveError(error) }
            }
        } catch { showProjectSaveError(error) }
    }

    private func showProjectSaveError(_ error: Error) {
        Task { @MainActor in
            canRecoverSavedProject = await persistence.canRecoverSavedProject()
            alertMessage = "Your changes are active but could not be saved. Retry Save applied changes in Edit.\n\n\(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func loadAnimation(from url: URL) async throws {
        statusMessage = "Loading animation..."

        let data = try Data(contentsOf: url)
        try await loadAnimation(data: data, sourceURL: url)
        statusMessage = ""
    }

    private func loadAnimation(data: Data, sourceURL: URL) async throws {
        launchTask?.cancel()
        try LottieImportService.validate(data)

        let candidate = AnimationDocument()
        try candidate.load(data: data, sourceURL: sourceURL)
        guard let candidateData = candidate.renderedData else {
            throw AnimationDocumentError.invalidRootObject
        }
        try await configurePlayer(
            with: candidateData,
            runtime: .embedded,
            baseURL: sourceURL.deletingLastPathComponent(),
            preservingProgress: false
        )

        try document.load(data: data, sourceURL: sourceURL)
        session.speed = document.edits.playbackSpeed
        session.loopMode = document.playbackLoopMode
        runtimeStatusMessage = document.hasRenderingLimitations
            ? "Gaussian Blur rendered with lottie-web"
            : "Loaded with \(document.selectedRuntime.title)"
        if persistenceEnabled {
            do { try await persistence.save(document) }
            catch { showProjectSaveError(error) }
        }
    }

    private func reloadAnimationFromDocument() async throws {
        try await configurePlayer(
            with: document.renderedData,
            runtime: document.selectedRuntime,
            baseURL: document.assetBaseURL,
            preservingProgress: true
        )
        session.speed = document.edits.playbackSpeed
    }

    private func configurePlayer(
        with data: Data?,
        runtime: LottieRuntimeVersion,
        baseURL: URL? = nil,
        preservingProgress: Bool = false
    ) async throws {
        guard let data else {
            throw AnimationDocumentError.invalidRootObject
        }

        try await session.load(
            data: data,
            runtime: runtime,
            baseURL: baseURL,
            preservingPlayback: preservingProgress
        )
    }

    private func switchRuntime(to runtime: LottieRuntimeVersion) {
        guard document.isLoaded,
              runtime != document.selectedRuntime,
              !isSwitchingRuntime else { return }

        let previousRuntime = document.selectedRuntime
        runtimeStatusMessage = ""

        Task { @MainActor in
            do {
                guard let data = document.renderedData else { return }
                try await session.switchRuntime(
                    data: data,
                    runtime: runtime,
                    baseURL: document.assetBaseURL
                )
                document.selectRuntime(runtime)
                scheduleProjectSave()
                runtimeStatusMessage = document.hasRenderingLimitations
                    ? "Gaussian Blur uses the shared lottie-web renderer"
                    : "Rendered successfully with \(runtime.title)"
            } catch is CancellationError {
                // Back or a newer import/switch superseded this request.
            } catch {
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
                if let report = pendingAssetRepairReport { sheets.present(.importReport(report)) }
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
                if imported.report.animations.count > 1 {
                    pendingPackageCleanupURL = imported.packageURL
                    sheets.present(.animationPicker(imported))
                } else {
                    try await finishImport(imported)
                }
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

    private func discardPendingPackage() {
        if let selection = pendingAnimationSelection {
            pendingAnimationSelection = nil
            pendingPackageCleanupURL = nil
            selectImportedAnimation(path: selection.path, in: selection.file)
            return
        }
        if let url = pendingPackageCleanupURL {
            try? FileManager.default.removeItem(at: url)
            pendingPackageCleanupURL = nil
        }
    }

    private func selectImportedAnimation(path: String, in imported: ImportedLottieFile) {
        isImporting = true
        statusMessage = "Preparing selected animation…"
        Task { @MainActor in
            defer { isImporting = false; statusMessage = "" }
            do {
                let selected = try await LottieImportService.selectAnimation(path: path, in: imported)
                try await finishImport(selected)
            } catch {
                try? FileManager.default.removeItem(at: imported.packageURL)
                alertMessage = "Import failed: \(error.localizedDescription)"
                showingAlert = true
            }
        }
    }

    private func finishImport(_ imported: ImportedLottieFile) async throws {
        try await loadAnimation(data: imported.data, sourceURL: imported.url)
        statusMessage = "Testing runtime compatibility…"
        importCompatibilityResults = makeCompatibilityMatrix(
            data: document.renderedData ?? imported.data,
            baseURL: imported.url.deletingLastPathComponent()
        )
        sheets.present(.importReport(imported.report))
    }

    private func beginMissingAssetRepair(from report: LottieImportReport) {
        softHaptic()
        pendingAssetRepairReport = report
        showAssetPickerAfterDismiss = true
        sheets.dismiss()
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
                try await loadAnimation(data: data, sourceURL: repairedReport.animationURL)
                importCompatibilityResults = makeCompatibilityMatrix(
                    data: document.renderedData ?? data,
                    baseURL: repairedReport.animationURL.deletingLastPathComponent()
                )
                sheets.present(.importReport(repairedReport))
                statusMessage = ""
            } catch {
                statusMessage = ""
                sheets.present(.importReport(report))
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
        session.close()
        statusMessage = ""
        runtimeStatusMessage = ""
        pendingAssetRepairReport = nil
        importCompatibilityResults = []
    }

    // MARK: - Playback Controls
    private func togglePlayback() {
        guard hasAnimation else { return }
        playControlAnimationTick += 1
        softHaptic()
        
        if isPlaying {
            session.pause()
        } else {
            session.play()
        }
    }
    
    private func previousFrame() {
        guard hasAnimation else { return }
        previousControlAnimationTick += 1
        softHaptic()
        session.step(by: -1)
    }
    
    private func nextFrame() {
        guard hasAnimation else { return }
        nextControlAnimationTick += 1
        softHaptic()
        session.step(by: 1)
    }
    
    private func seekToFrame(_ frame: Double) {
        guard hasAnimation else { return }
        session.seek(progress: totalFrames > 0 ? frame / totalFrames : 0)
    }
    
    private func setSpeed(_ speed: Double) {
        softHaptic()
        print("⚡ ContentView: Setting speed to \(speed)x")
        session.speed = speed
        document.updatePlaybackSpeed(speed)
        scheduleProjectSave()
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
        session.loopMode = mode
        document.updateLoopMode(mode)
        scheduleProjectSave()
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
    
    
    // MARK: - Test Helper
    private func loadFirstSampleAnimation() {
        print("🧪 ContentView: Auto-loading first sample animation for testing")
        print("🧪 ContentView: Bundle path: \(Bundle.main.bundlePath)")
        
        // Try to load the first available sample animation
        let sampleAnimations = [
            "note_outline_music_sa_outline_to_fill_28.json",
            "compass_music_sa_outline_to_fill_28.json",
            "heart_list_music_sa_outline_to_fill_28.json",
            "horse_toy_outline_music_sa_outline_to_fill_28.json",
            "podcast_books_outline_music_sa_outline_to_fill_28.json",
            "radio_outline_music_sa_outline_to_fill_28.json"
        ]
        
        for animationName in sampleAnimations {
            // Try with exact name first
            if let url = Bundle.main.url(forResource: animationName, withExtension: nil) {
                print("🧪 ContentView: Found sample animation: \(animationName)")
                Task { try? await loadAnimation(from: url) }
                return
            }
            
            // Try without extension
            let nameWithoutExtension = animationName.replacingOccurrences(of: ".json", with: "")
            if let url = Bundle.main.url(forResource: nameWithoutExtension, withExtension: "json") {
                print("🧪 ContentView: Found sample animation: \(nameWithoutExtension).json")
                Task { try? await loadAnimation(from: url) }
                return
            }
        }
        
        print("🧪 ContentView: No sample animations found in bundle")
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
                    if !report.warnings.isEmpty {
                        reportSection("Package compatibility") {
                            ForEach(report.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
            || !report.warnings.isEmpty
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

struct PreviewCheckerboardView: View {
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

import SwiftUI

struct MainExportView: View {
    @ObservedObject var document: AnimationDocument
    @Environment(\.dismiss) private var dismiss

    @State private var exportFormat: AnimationExportFormat = .gif
    @State private var framesPerSecond = 30
    @State private var exportSpeed = 1.0
    @State private var exportWidth = 512
    @State private var exportHeight = 512
    @State private var gifQuality = 0.9
    @State private var transparent = true
    @State private var exportBackground = Color.white
    @State private var previewPlayer: VersionedLottiePlayerView?

    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress = 0.0
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var alertMessage = ""
    @State private var showingAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    formatSection

                    if exportFormat != .json {
                        previewSection
                        sizeSection
                        frameRateSection
                        playbackSection
                        appearanceSection
                        if exportFormat == .gif {
                            qualitySection
                        }
                    }

                    if isExporting {
                        progressSection
                    }

                    exportButtons
                }
                .padding()
            }
            .navigationTitle("Export Animation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isExporting ? "Cancel Export" : "Close") {
                        if isExporting {
                            cancelExport()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let exportURL {
                ShareSheet(items: [exportURL])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .alert("Export Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            applyOriginalSize()
            exportSpeed = sanitizedSpeed(document.edits.playbackSpeed)
            reloadPreview()
        }
        .onChange(of: exportFormat) { _, newFormat in
            if !newFormat.supportsTransparency {
                transparent = false
            }
            reloadPreview()
        }
        .onChange(of: transparent) { _, _ in reloadPreview() }
        .onChange(of: exportBackground) { _, _ in reloadPreview() }
        .onChange(of: exportSpeed) { _, _ in reloadPreview() }
        .onDisappear {
            exportTask?.cancel()
            previewPlayer?.stop()
        }
    }

    private var formatSection: some View {
        settingsCard(title: "Export Format") {
            Picker("Format", selection: $exportFormat) {
                ForEach(AnimationExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Text(formatDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewSection: some View {
        settingsCard(title: "Preview") {
            ZStack {
                if transparent {
                    CheckerboardView()
                } else {
                    exportBackground
                }

                if let previewPlayer {
                    LottieView(animationView: previewPlayer)
                        .onAppear { previewPlayer.play() }
                } else {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator, lineWidth: 1)
            }
        }
    }

    private var sizeSection: some View {
        settingsCard(title: "Output Size") {
            HStack {
                sizePresetButton("Original") { applyOriginalSize() }
                sizePresetButton("512 px") { applyMaximumDimension(512) }
                sizePresetButton("1024 px") { applyMaximumDimension(1024) }
            }

            HStack(spacing: 12) {
                dimensionField("Width", value: $exportWidth)
                Image(systemName: "multiply")
                    .foregroundStyle(.secondary)
                dimensionField("Height", value: $exportHeight)
            }

            if exportFormat == .mp4 || exportFormat == .mov {
                Text("Video dimensions are rounded up to even pixel values when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var frameRateSection: some View {
        settingsCard(title: "Frame Rate") {
            Picker("FPS", selection: $framesPerSecond) {
                ForEach([15, 24, 30, 60], id: \.self) { fps in
                    Text("\(fps)").tag(fps)
                }
            }
            .pickerStyle(.segmented)

            if let duration = document.metadata?.duration {
                let outputDuration = exportDuration(from: duration)
                Text("\(frameCount(duration: outputDuration)) frames · \(outputDuration.formatted(.number.precision(.fractionLength(2)))) seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playbackSection: some View {
        settingsCard(title: "Playback") {
            HStack {
                Slider(value: $exportSpeed, in: 0.1...3.0, step: 0.1)
                Text("\(exportSpeed, specifier: "%.1f")×")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }

            if let duration = document.metadata?.duration {
                Text("Raster export uses this speed: \(duration.formatted(.number.precision(.fractionLength(2))))s source → \(exportDuration(from: duration).formatted(.number.precision(.fractionLength(2))))s output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        settingsCard(title: "Background") {
            Toggle("Transparent background", isOn: $transparent)
                .disabled(!exportFormat.supportsTransparency)

            if !transparent {
                ColorPicker("Background color", selection: $exportBackground, supportsOpacity: false)
            }

            if exportFormat == .mp4 {
                Text("MP4/H.264 does not support alpha. Choose MOV for transparent video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if exportFormat == .mov && transparent {
                Text("Transparent MOV uses HEVC with Alpha and requires compatible Apple hardware/software.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qualitySection: some View {
        settingsCard(title: "GIF Quality") {
            HStack {
                Slider(value: $gifQuality, in: 0.3...1, step: 0.1)
                Text("\(Int((gifQuality * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var progressSection: some View {
        settingsCard(title: "Exporting \(exportFormat.rawValue)") {
            ProgressView(value: exportProgress)
            Text("\(Int((exportProgress * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var exportButtons: some View {
        VStack(spacing: 10) {
            Button(action: startExport) {
                Label(
                    isExporting ? "Exporting…" : "Export \(exportFormat.rawValue)",
                    systemImage: exportFormat.systemImage
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStartExport)

            if isExporting {
                Button("Cancel Export", role: .destructive, action: cancelExport)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var formatDescription: String {
        switch exportFormat {
        case .json:
            "Exports the edited Lottie JSON without rasterizing it."
        case .gif:
            "Frames are rendered and written directly to the GIF without keeping the full animation in memory."
        case .mp4:
            "H.264 video with broad compatibility and an opaque background."
        case .mov:
            "QuickTime video. Transparency is encoded with HEVC with Alpha."
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sizePresetButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func dimensionField(
        _ title: String,
        value: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func applyOriginalSize() {
        guard let metadata = document.metadata else { return }
        exportWidth = max(1, metadata.width)
        exportHeight = max(1, metadata.height)
    }

    private func applyMaximumDimension(_ maximum: Int) {
        guard let metadata = document.metadata,
              metadata.width > 0,
              metadata.height > 0 else {
            exportWidth = maximum
            exportHeight = maximum
            return
        }

        let scale = Double(maximum) / Double(max(metadata.width, metadata.height))
        exportWidth = max(1, Int((Double(metadata.width) * scale).rounded()))
        exportHeight = max(1, Int((Double(metadata.height) * scale).rounded()))
    }

    private func frameCount(duration: Double) -> Int {
        max(1, Int(ceil(duration * Double(framesPerSecond))))
    }

    private var canStartExport: Bool {
        document.isLoaded
            && !isExporting
            && exportWidth > 0
            && exportHeight > 0
            && framesPerSecond > 0
            && exportSpeed > 0
    }

    private func sanitizedSpeed(_ speed: Double) -> Double {
        min(max(speed, 0.1), 3.0)
    }

    private func exportDuration(from sourceDuration: Double) -> Double {
        sourceDuration / sanitizedSpeed(exportSpeed)
    }

    private func makePlan() -> AnimationExportPlan {
        AnimationExportPlan(
            format: exportFormat,
            size: CGSize(width: exportWidth, height: exportHeight),
            framesPerSecond: framesPerSecond,
            duration: document.metadata.map { exportDuration(from: $0.duration) } ?? 0,
            transparent: exportFormat == .json ? false : transparent,
            backgroundColor: RGBAColor(exportBackground),
            gifQuality: gifQuality
        )
    }

    private func animationDataForExport() throws -> Data {
        guard exportFormat != .json else {
            guard let data = document.renderedData else {
                throw AnimationDocumentError.invalidRootObject
            }
            return data
        }
        guard let originalData = document.originalData else {
            throw AnimationDocumentError.invalidRootObject
        }

        var edits = document.edits
        edits.backgroundColor = transparent ? nil : RGBAColor(exportBackground)
        return try AnimationDocument.renderedData(from: originalData, edits: edits)
    }

    private func reloadPreview() {
        guard exportFormat != .json else {
            previewPlayer?.stop()
            previewPlayer = nil
            return
        }

        do {
            let player = VersionedLottiePlayerView()
            _ = try player.load(
                data: animationDataForExport(),
                runtime: document.selectedRuntime,
                baseURL: document.sourceURL?.deletingLastPathComponent()
            )
            player.contentMode = .scaleAspectFit
            player.loopMode = .loop
            player.animationSpeed = exportSpeed
            player.backgroundColor = .clear
            previewPlayer?.stop()
            previewPlayer = player
            player.play()
        } catch {
            previewPlayer?.stop()
            previewPlayer = nil
        }
    }

    private func startExport() {
        exportTask?.cancel()
        isExporting = true
        exportProgress = 0

        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportTask = nil
            }

            do {
                let request = AnimationExportRequest(
                    animationData: try animationDataForExport(),
                    runtime: document.selectedRuntime,
                    plan: makePlan(),
                    assetBaseURL: document.sourceURL?.deletingLastPathComponent(),
                    preferredFileName: document.displayName
                )
                let url = try await AnimationExporter().export(request: request) {
                    exportProgress = $0
                }
                try Task.checkCancellation()
                exportURL = url
                showingShareSheet = true
            } catch is CancellationError {
                exportProgress = 0
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
    }
}

private struct CheckerboardView: View {
    private let columns = Array(
        repeating: GridItem(.fixed(16), spacing: 0),
        count: 24
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(0..<336, id: \.self) { index in
                Rectangle()
                    .fill((index + index / 24).isMultiple(of: 2) ? Color.white : Color.gray.opacity(0.25))
                    .frame(height: 16)
            }
        }
        .clipped()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

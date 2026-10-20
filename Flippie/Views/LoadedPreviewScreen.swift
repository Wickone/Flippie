import SwiftUI

/// Only the layout changes with the viewport; PlaybackSession owns the live view.
struct LoadedPreviewScreen: View {
    @ObservedObject var document: AnimationDocument
    @ObservedObject var session: PlaybackSession
    var reservedBottomSpace: CGFloat = 0
    let onBack: () -> Void
    let onProfile: () -> Void
    let onSettings: () -> Void
    let onPlay: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var infoFontSize = 11.0

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let wide = Self.usesSideBySideLayout(in: proxy.size)
                let scale = wide ? 1 : min(560, max(320, proxy.size.width)) / 393
                let arrangement = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                    : AnyLayout(VStackLayout(spacing: dynamicType.isAccessibilitySize ? 20 : 0))
                // Keep the pre-lift card dimensions; the real ScrollView still
                // uses the smaller viewport and can scroll above the raised bar.
                let previewSpace = CGSize(width: proxy.size.width, height: proxy.size.height + reservedBottomSpace)
                let availableHeight = Self.previewHeight(in: previewSpace, wide: wide, largeType: dynamicType.isAccessibilitySize)
                let cardHeight = wide || dynamicType.isAccessibilitySize
                    ? availableHeight : min(362 * scale, availableHeight)
                let topInset = wide || dynamicType.isAccessibilitySize ? 16
                    : max(16, 132 * scale - proxy.frame(in: .named("preview-layout")).minY)
                ScrollView {
                    // AnyLayout changes the arrangement, not the identity or window
                    // attachment of the live renderer (especially lottie-ios 3.5).
                    arrangement {
                        previewCard(scale: scale)
                            .frame(width: wide ? min(420, (proxy.size.width - 56) * 0.48) : nil,
                                   height: cardHeight)
                        detailsAndControls(scale: scale, wide: wide)
                            .frame(maxWidth: wide ? 420 : .infinity)
                    }
                    .frame(maxWidth: wide ? .infinity : 560)
                    .padding(.horizontal, 16)
                    .padding(.top, topInset)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(FlippieScreenBackground().ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left", action: onBack)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityIdentifier("close-preview")
                }
                ToolbarItem(placement: .principal) { FlippieNavigationLogo() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Profile", systemImage: "person.crop.circle", action: onProfile)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 28, weight: .medium))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .coordinateSpace(name: "preview-layout")
        .tint(Color.primary)
        .environment(\.colorScheme, .light)
    }

    private func previewCard(scale: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            PreviewCheckerboardView(squareSize: 11 * scale)
            LottieView(animationView: session.player)
                .padding(22 * scale)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if let pending = session.pendingRuntime {
                Rectangle().fill(.ultraThinMaterial)
                ProgressView("Loading \(pending.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("Playback settings", systemImage: "ellipsis", action: onSettings)
                .labelStyle(.iconOnly)
                .font(.system(size: 17 * scale, weight: .bold))
                .frame(width: max(44, 44 * scale), height: max(44, 44 * scale))
                .previewGlassBackground(shape: Circle())
                .buttonStyle(.plain)
                .padding(17 * scale)
                .accessibilityIdentifier("playback-settings")
        }
        .clipShape(RoundedRectangle(cornerRadius: 58 * scale, style: .continuous))
        .shadow(color: Color(red: 0, green: 0.06, blue: 0.55).opacity(0.24), radius: 22, x: 0, y: 18)
    }

    static func previewHeight(in size: CGSize, wide: Bool, largeType: Bool) -> CGFloat {
        let height = wide ? max(120, min(420, size.height - 32))
            : min(min(560, size.width - 32), max(160, size.height - (largeType ? 340 : 230)))
        return max(0, height)
    }

    static func usesSideBySideLayout(in size: CGSize) -> Bool {
        // Two columns need at least 282pt for the unchanged playback row.
        size.width > size.height * 1.25 && size.width >= 600
    }

    private func detailsAndControls(scale: CGFloat, wide: Bool) -> some View {
        let adaptive = wide || dynamicType.isAccessibilitySize
        return VStack(spacing: adaptive ? 24 : 43 * scale) {
            Text(infoText)
                .font(dynamicType.isAccessibilitySize ? .caption : .system(size: infoFontSize))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, dynamicType.isAccessibilitySize ? 12 : 8)
                .padding(.vertical, dynamicType.isAccessibilitySize ? 6 : 4)
                .background(.white.opacity(0.18), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 0.8))
                .frame(minHeight: adaptive ? nil : 44 * scale)
                .accessibilityLabel("Animation progress")
                .accessibilityValue(infoText)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onNext()
                    case .decrement: onPrevious()
                    @unknown default: break
                    }
                }
            controls(scale: scale)
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder private func controls(scale: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 32 * scale) { controlButtons(scale: scale) }
        } else { controlButtons(scale: scale) }
    }

    private func controlButtons(scale: CGFloat) -> some View {
        HStack(spacing: 32 * scale) {
            control(label: "Previous frame", size: 64 * scale, action: onPrevious) {
                SkipControlIcon(direction: .backward).frame(width: 37 * scale, height: 37 * scale)
            }
            control(label: session.isPlaying ? "Pause" : "Play", size: 90 * scale, action: onPlay) {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44 * scale, weight: .medium))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            control(label: "Next frame", size: 64 * scale, action: onNext) {
                SkipControlIcon(direction: .forward).frame(width: 37 * scale, height: 37 * scale)
            }
        }
    }

    private func control<Icon: View>(label: String, size: CGFloat, action: @escaping () -> Void,
                                     @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .controlGlassBackground(shape: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(label == "Play" || label == "Pause" ? "play-pause" : label)
    }

    private var infoText: String {
        guard let metadata = document.metadata else { return "No animation" }
        let duration = String(format: "%.2fs", metadata.duration).replacingOccurrences(of: ".", with: ",")
        return "\(Int(session.currentFrame.rounded()))/\(Int(session.totalFrames.rounded())) • "
            + duration
            + " • \(Int(metadata.frameRate.rounded())) fps • Canvas \(metadata.width)x\(metadata.height)"
    }
}

struct FlippieNavigationLogo: View {
    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            Text("flippie").font(.system(size: 30, weight: .black, design: .rounded)).kerning(-0.8)
            Image(systemName: "play.fill").font(.system(size: 8, weight: .black)).padding(.top, 7)
        }
        .foregroundStyle(.white.opacity(0.92))
        .accessibilityLabel("Flippie")
    }
}

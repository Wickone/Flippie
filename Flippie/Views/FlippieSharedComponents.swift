import SwiftUI

struct FlippieBlinkingLogo: View {
    let size: CGFloat
    @State private var isBlinking = false
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Image("EmptyFlippieLogo")
                .resizable()
                .scaledToFit()
                .opacity(isBlinking ? 0 : 1)

            Image("EmptyFlippieLogoBlink")
                .resizable()
                .scaledToFit()
                .opacity(isBlinking ? 1 : 0)
        }
        .frame(width: size, height: size)
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear {
            guard blinkTask == nil else { return }
            blinkTask = Task {
                while !Task.isCancelled {
                    let pause = UInt64(Double.random(in: 2.4...4.8) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: pause)
                    guard !Task.isCancelled else { break }

                    await MainActor.run {
                        withTransaction(Transaction(animation: nil)) {
                            isBlinking = true
                        }
                    }

                    try? await Task.sleep(nanoseconds: 140_000_000)
                    guard !Task.isCancelled else { break }

                    await MainActor.run {
                        withTransaction(Transaction(animation: nil)) {
                            isBlinking = false
                        }
                    }
                }
            }
        }
        .onDisappear {
            blinkTask?.cancel()
            blinkTask = nil
            isBlinking = false
        }
    }
}

struct SkipControlIcon: View {
    enum Direction {
        case backward
        case forward
    }

    let direction: Direction

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(2.6, size * 0.075)
            let barWidth = max(3.2, size * 0.082)
            let barHeight = size * 0.84
            let barInset = size * 0.16
            let gap = size * 0.16
            let triangleWidth = size * 0.52
            let triangleHeight = size * 0.64
            let centerY = proxy.size.height / 2
            let top = centerY - triangleHeight / 2
            let bottom = centerY + triangleHeight / 2

            ZStack {
                if direction == .forward {
                    let barX = (proxy.size.width - size) / 2 + barInset
                    let triangleLeft = barX + barWidth + gap

                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(.white)
                        .frame(width: barWidth, height: barHeight)
                        .position(x: barX + barWidth / 2, y: centerY)

                    Path { path in
                        path.move(to: CGPoint(x: triangleLeft, y: top))
                        path.addLine(to: CGPoint(x: triangleLeft + triangleWidth, y: centerY))
                        path.addLine(to: CGPoint(x: triangleLeft, y: bottom))
                        path.closeSubpath()
                    }
                    .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                } else {
                    let barX = (proxy.size.width + size) / 2 - barInset - barWidth
                    let triangleRight = barX - gap

                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(.white)
                        .frame(width: barWidth, height: barHeight)
                        .position(x: barX + barWidth / 2, y: centerY)

                    Path { path in
                        path.move(to: CGPoint(x: triangleRight, y: top))
                        path.addLine(to: CGPoint(x: triangleRight - triangleWidth, y: centerY))
                        path.addLine(to: CGPoint(x: triangleRight, y: bottom))
                        path.closeSubpath()
                    }
                    .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

extension View {
    @ViewBuilder
    func lightTabGlassBackground<S: Shape>(shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .regular
                        .tint(Color(red: 0.82, green: 0.87, blue: 1.0).opacity(0.86))
                        .interactive(),
                    in: shape
                )
        } else {
            self
                .background {
                    shape
                        .fill(Color(red: 0.82, green: 0.87, blue: 1.0).opacity(0.88))
                }
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func selectedTabGlassBackground<S: Shape>(isSelected: Bool, shape: S) -> some View {
        if isSelected {
            if #available(iOS 26.0, *) {
                self
                    .glassEffect(
                        .regular
                            .tint(Color.white.opacity(0.42))
                            .interactive(),
                        in: shape
                    )
            } else {
                self
                    .background {
                        shape
                            .fill(Color.white.opacity(0.28))
                    }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func liquidGlassBackground<S: Shape>(shape: S, cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                }
                .background {
                    shape
                        .fill(Color.white.opacity(0.62))
                }
                .overlay {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
        }
    }

    @ViewBuilder
    func previewGlassBackground<S: Shape>(shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                }
                .background {
                    shape
                        .fill(Color.white.opacity(0.66))
                }
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8)
        }
    }

    @ViewBuilder
    func controlGlassBackground<S: Shape>(shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.clear.interactive(), in: shape)
        } else {
            self
                .background {
                    shape
                        .fill(Color.white.opacity(0.34))
                        .blendMode(.softLight)
                }
                .overlay {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.07),
                                    Color.white.opacity(0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 10)
        }
    }
}

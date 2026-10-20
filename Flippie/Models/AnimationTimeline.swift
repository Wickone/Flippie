import Foundation

/// `op` is an exclusive render boundary; control progress may still reach 1.
struct AnimationTimeline: Equatable, Sendable {
    let startFrame: Double
    let endFrame: Double
    let frameRate: Double
    var frameCount: Double { max(0, endFrame - startFrame) }
    var duration: Double { frameRate > 0 ? frameCount / frameRate : 0 }
    var lastRenderableFrame: Double { max(startFrame, endFrame - min(0.001, frameCount / 2)) }

    func absoluteFrame(forProgress progress: Double) -> Double {
        startFrame + Self.unit(progress) * frameCount
    }

    func progress(forAbsoluteFrame frame: Double) -> Double {
        guard frameCount > 0 else { return 0 }
        return Self.unit((frame - startFrame) / frameCount)
    }

    func renderableFrame(forProgress progress: Double) -> Double {
        min(absoluteFrame(forProgress: progress), lastRenderableFrame)
    }

    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

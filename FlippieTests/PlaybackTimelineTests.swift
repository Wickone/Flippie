import XCTest
@testable import Flippie

@MainActor
final class PlaybackTimelineTests: XCTestCase {
    func testOffsetTimelineUsesAbsoluteFrames() {
        let timeline = AnimationTimeline(startFrame: 60, endFrame: 120, frameRate: 60)
        XCTAssertEqual(timeline.absoluteFrame(forProgress: 0), 60)
        XCTAssertEqual(timeline.absoluteFrame(forProgress: 0.5), 90)
        XCTAssertEqual(timeline.progress(forAbsoluteFrame: 60), 0)
        XCTAssertEqual(timeline.progress(forAbsoluteFrame: 90), 0.5)
        XCTAssertEqual(timeline.duration, 1)
    }

    func testTimelineClampsBoundariesAndNonFiniteInput() {
        let timeline = AnimationTimeline(startFrame: 60, endFrame: 120, frameRate: 60)
        XCTAssertEqual(timeline.absoluteFrame(forProgress: -1), 60)
        XCTAssertEqual(timeline.absoluteFrame(forProgress: 2), 120)
        XCTAssertEqual(timeline.absoluteFrame(forProgress: .nan), 60)
        XCTAssertEqual(timeline.progress(forAbsoluteFrame: 40), 0)
        XCTAssertEqual(timeline.progress(forAbsoluteFrame: 200), 1)
    }

    func testNativeAndWebExposeSameAbsoluteFrames() async throws {
        for blur in [false, true] {
            for runtime in LottieRuntimeVersion.allCases {
                let player = VersionedLottiePlayerView()
                _ = try player.load(data: Stage4Fixture.animation(blur: blur), runtime: runtime)
                defer { player.unload() }
                try await player.prepareFrame(progress: 0)
                XCTAssertEqual(player.currentFrame, 60, accuracy: 0.01, "\(runtime) blur=\(blur)")
                try await player.prepareFrame(progress: 0.5)
                XCTAssertEqual(player.currentFrame, 90, accuracy: 0.01)
                player.currentFrame = 61
                XCTAssertEqual(player.currentProgress, 1.0 / 60, accuracy: 0.001)
            }
        }
    }

    func testSessionFrameStepMatchesForNativeAndWeb() async throws {
        for blur in [false, true] {
            let session = PlaybackSession()
            try await session.load(data: Stage4Fixture.animation(blur: blur), runtime: .v461, baseURL: nil)
            defer { session.close() }
            session.step(by: 1)
            XCTAssertEqual(session.currentFrame, 1, accuracy: 0.01)
            XCTAssertEqual(session.player.currentFrame, 61, accuracy: 0.01)
        }
    }

    func testFinalPreparedFrameStaysBeforeExclusiveOutPoint() async throws {
        for blur in [false, true] {
            let player = VersionedLottiePlayerView()
            _ = try player.load(data: Stage4Fixture.animation(blur: blur), runtime: .v461)
            defer { player.unload() }
            try await player.prepareFrame(progress: 1)
            XCTAssertGreaterThan(player.currentFrame, 119)
            XCTAssertLessThan(player.currentFrame, 120)
        }
    }

    func testStopRestoresAbsoluteStartForNativeAndWeb() async throws {
        for blur in [false, true] {
            for runtime in LottieRuntimeVersion.allCases {
                let player = VersionedLottiePlayerView()
                _ = try player.load(data: Stage4Fixture.animation(blur: blur), runtime: runtime)
                defer { player.unload() }
                try await player.prepareFrame(progress: 0.5)
                player.stop()
                XCTAssertEqual(player.currentFrame, 60, accuracy: 0.01)
                XCTAssertEqual(player.currentProgress, 0, accuracy: 0.001)
            }
        }
    }

    func testSnapshotsFollowPreparedFrameWithBlurMaskAndOffset() async throws {
        for blur in [false, true] {
            let renderer = try AnimationFrameRenderer(
                animationData: Stage4Fixture.animation(blur: blur, mask: true), runtime: .v461,
                size: CGSize(width: 100, height: 100), transparent: true,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0)
            )
            for (index, progress) in [0.0, 0.5, 1.0].enumerated() {
                print("FRAME PIXELS: blur=\(blur), progress=\(progress)")
                let image = try await renderer.render(progress: progress, frameIndex: index)
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "offset-mask-\(blur ? "blur" : "native")-\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let center = try Stage4Fixture.redCenter(image)
                XCTAssertEqual(center, 15 + progress * 60, accuracy: 3, "blur=\(blur), progress=\(progress)")
            }
        }
    }
}

import XCTest
import SwiftUI
@testable import Flippie

@MainActor
final class PlaybackSessionTests: XCTestCase {
    private func animation(frames: Int = 60) -> Data {
        Data("{\"v\":\"5.7.0\",\"fr\":60,\"ip\":0,\"op\":\(frames),\"w\":100,\"h\":100,\"layers\":[]}".utf8)
    }

    func testFailedRuntimeSwitchPreservesFrameAndPlayback() async throws {
        let session = PlaybackSession()
        let window = mount(session.player)
        defer { session.close(); window.isHidden = true }
        try await session.load(data: animation(), runtime: .v461, baseURL: nil)
        session.seek(progress: 0.4)
        session.play()
        try await Task.sleep(for: .milliseconds(60))
        let visibleProgress = session.player.currentProgress
        let engine = session.player.subviews.first
        do {
            try await session.load(data: Data("{}".utf8), runtime: .v300, baseURL: nil, preservingPlayback: true)
            XCTFail("Invalid candidate must fail")
        } catch { }
        XCTAssertTrue(session.player.subviews.first === engine)
        XCTAssertGreaterThan(visibleProgress, 0.3)
        XCTAssertEqual(session.player.currentProgress, visibleProgress, accuracy: 0.03)
        XCTAssertTrue(session.isPlaying)
        XCTAssertTrue(session.isTrackingProgress)
        XCTAssertEqual(session.readiness, .ready)
        session.close()
    }

    func testPlayOncePublishesStoppedState() async throws {
        let session = PlaybackSession()
        let window = mount(session.player)
        defer { session.close(); window.isHidden = true }
        try await session.load(data: animation(frames: 6), runtime: .v461, baseURL: nil)
        session.loopMode = .playOnce
        session.play()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isTrackingProgress)
        XCTAssertEqual(session.progress, 1, accuracy: 0.02)
    }

    func testFrameStepPausesPlayback() async throws {
        let session = PlaybackSession()
        let window = mount(session.player)
        defer { session.close(); window.isHidden = true }
        try await session.load(data: animation(), runtime: .v461, baseURL: nil)
        session.seek(progress: 0.4)
        session.play()
        try await Task.sleep(for: .milliseconds(60))
        let visibleFrame = session.player.currentProgress * session.totalFrames
        session.step(by: 1)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isTrackingProgress)
        XCTAssertGreaterThan(visibleFrame, 20)
        XCTAssertEqual(session.currentFrame, visibleFrame + 1, accuracy: 2)
        session.close()
    }

    func testOpeningSheetKeepsPreviewIdentity() async throws {
        let session = PlaybackSession()
        let sheets = SheetCoordinator()
        try await session.load(data: animation(), runtime: .v461, baseURL: nil)
        session.play()
        let preview = session.player
        let engine = preview.subviews.first
        for route in [SheetRoute.edit, .export, .playbackSettings] {
            sheets.present(route)
            XCTAssertTrue(session.player === preview)
            XCTAssertTrue(session.player.subviews.first === engine)
            XCTAssertTrue(session.isPlaying)
            sheets.dismiss()
            sheets.didDismiss()
        }
        session.close()
    }

    func testRendererComparisonWaitsForSettingsDismissal() {
        let sheets = SheetCoordinator()
        sheets.present(.playbackSettings)
        sheets.present(.rendererComparison)
        XCTAssertNil(sheets.active)
        sheets.didDismiss()
        XCTAssertEqual(sheets.active?.id, SheetRoute.rendererComparison.id)
    }

    func testBackgroundPausesAndForegroundResumesOnlyPreviouslyPlaying() async throws {
        let session = PlaybackSession()
        try await session.load(data: animation(), runtime: .v461, baseURL: nil)
        session.play()
        session.setSceneActive(false)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isTrackingProgress)
        session.setSceneActive(true)
        XCTAssertTrue(session.isPlaying)
        session.setSceneActive(false)
        session.pause()
        session.setSceneActive(true)
        XCTAssertFalse(session.isPlaying)
        session.close()
        XCTAssertEqual(session.readiness, .empty)
    }

    private func mount(_ view: UIView) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController!.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.makeKeyAndVisible()
        return window
    }

    func testNativeModalCycleKeepsPreviewVisible() async throws {
        try await modalCycle(blur: false)
    }

    func testBlurModalCycleKeepsPreviewVisible() async throws {
        try await modalCycle(blur: true)
    }

    func testCloseInvalidatesPendingWebCandidate() async throws {
        let session = PlaybackSession()
        let data = try fixture(blur: true)
        let loading = Task { try await session.load(data: data, runtime: .v461, baseURL: nil) }
        await Task.yield()
        session.close()
        do { try await loading.value; XCTFail("Closed session must not install a pending candidate") }
        catch is CancellationError { }
        XCTAssertFalse(session.hasAnimation)
        XCTAssertEqual(session.readiness, .empty)
        XCTAssertTrue(session.player.subviews.isEmpty)
    }

    func testEveryNativeRuntimeCompletesPlayOnce() async throws {
        for runtime in LottieRuntimeVersion.allCases {
            let session = PlaybackSession()
            let window = mount(session.player)
            try await session.load(data: animation(frames: 6), runtime: runtime, baseURL: nil)
            session.loopMode = .playOnce
            session.play()
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertFalse(session.isPlaying, runtime.title)
            XCTAssertFalse(session.isTrackingProgress, runtime.title)
            session.close()
            window.isHidden = true
        }
    }

    func testBlurPlayOncePublishesStoppedState() async throws {
        let session = PlaybackSession()
        let window = mount(session.player)
        defer { session.close(); window.isHidden = true }
        try await session.load(data: fixture(blur: true), runtime: .v461, baseURL: nil)
        XCTAssertEqual(session.readiness, .ready)
        session.loopMode = .playOnce
        session.speed = 8
        session.play()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isTrackingProgress)
        XCTAssertEqual(session.progress, 1, accuracy: 0.02)
    }

    private func modalCycle(blur: Bool) async throws {
        let session = PlaybackSession()
        let sheets = SheetCoordinator()
        let document = AnimationDocument()
        let data = try fixture(blur: blur)
        let host = UIHostingController(rootView: ContentView(document: document, session: session, sheets: sheets)
            .environment(\.colorScheme, .light)
            .environment(\.scenePhase, .active))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { session.close(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        try document.load(data: data)
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        try await Task.sleep(for: .milliseconds(400))
        session.play()
        let preview = session.player
        let engine = preview.subviews.first
        for route in [SheetRoute.edit, .export, .playbackSettings] {
            print("MODAL CYCLE \(blur ? "web" : "native"): \(route.id)")
            sheets.present(route)
            let presented = await eventually {
                host.presentedViewController != nil && host.presentedViewController?.isBeingPresented != true
            }
            XCTAssertTrue(presented)
            XCTAssertNotNil(host.presentedViewController)
            XCTAssertTrue(session.player === preview)
            XCTAssertTrue(session.player.subviews.first === engine)
            XCTAssertNotNil(preview.window, "Sheet must keep the live preview attached")
            XCTAssertTrue(session.isPlaying)
            sheets.dismiss()
            let dismissed = await eventually { host.presentedViewController == nil }
            XCTAssertTrue(dismissed)
            XCTAssertNil(host.presentedViewController)
            XCTAssertNotNil(preview.window)
            XCTAssertTrue(session.isPlaying)
        }
        try await session.load(data: data, runtime: .v300, baseURL: nil, preservingPlayback: true)
        document.selectRuntime(.v300)
        XCTAssertTrue(session.player === preview)
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(session.player.runtime, .v300)
        try await Task.sleep(for: .milliseconds(400))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = blur ? "web-preview-after-sheets" : "native-preview-after-sheets"
        attachment.lifetime = .keepAlways
        add(attachment)
        session.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(session.hasAnimation)
        XCTAssertTrue(session.player.subviews.isEmpty)
    }

    private func fixture(blur: Bool) throws -> Data {
        let transform: [String: Any] = [
            "o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0],
            "p": ["a": 1, "k": [
                ["t": 0, "s": [30, 50, 0], "e": [70, 50, 0], "o": ["x": 0.33, "y": 0], "i": ["x": 0.67, "y": 1]],
                ["t": 120, "s": [70, 50, 0]],
            ]],
            "a": ["a": 0, "k": [10, 10, 0]], "s": ["a": 0, "k": [100, 100, 100]],
        ]
        var layer: [String: Any] = [
            "ddd": 0, "ind": 1, "ty": 1, "nm": "Moving square", "sr": 1,
            "ks": transform, "sw": 20, "sh": 20, "sc": "#ff5533", "ip": 0, "op": 120, "st": 0, "bm": 0,
        ]
        if blur {
            layer["ef"] = [["ty": 29, "nm": "Gaussian Blur", "ef": [
                ["ty": 0, "v": ["a": 0, "k": 8]],
                ["ty": 7, "v": ["a": 0, "k": 1]],
                ["ty": 7, "v": ["a": 0, "k": 0]],
            ]]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "v": "5.7.0", "fr": 60, "ip": 0, "op": 120, "w": 100, "h": 100, "layers": [layer], "assets": [],
        ])
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testClosedRuntimeSwitchCannotClearNewerOperation() async throws {
        let oldGate = PreparationGate()
        let newGate = PreparationGate()
        let session = PlaybackSession { candidate in
            if candidate.runtime == .v300 { await oldGate.wait() }
            if candidate.runtime == .v350 { await newGate.wait() }
        }
        let data = animation()
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        let old = Task { try await session.switchRuntime(data: data, runtime: .v300, baseURL: nil) }
        await Task.yield()
        XCTAssertEqual(session.pendingRuntime, .v300)
        session.close()
        XCTAssertNil(session.pendingRuntime)
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        let newer = Task { try await session.switchRuntime(data: data, runtime: .v350, baseURL: nil) }
        await Task.yield()
        XCTAssertEqual(session.pendingRuntime, .v350)
        oldGate.release()
        do { try await old.value; XCTFail("Old switch must be cancelled") }
        catch is CancellationError { }
        XCTAssertEqual(session.pendingRuntime, .v350)
        newGate.release()
        try await newer.value
        XCTAssertNil(session.pendingRuntime)
        XCTAssertEqual(session.player.runtime, .v350)
        session.close()
    }

    func testApplyCommitsCapturedSpeedNotChangedDraft() async throws {
        let application = AnimationEditApplication()
        let document = AnimationDocument()
        try document.load(data: animation())
        var draft = AnimationEdits(playbackSpeed: 1.5)
        var playerSpeed = 1.0
        _ = try await application.apply(document: document, draft: { draft }, setPlaybackSpeed: { playerSpeed = $0 }) {
            XCTAssertTrue(application.isApplying)
            draft = AnimationEdits(playbackSpeed: 2)
            await Task.yield()
        }
        XCTAssertEqual(document.edits.playbackSpeed, 1.5)
        XCTAssertEqual(playerSpeed, document.edits.playbackSpeed)
        XCTAssertFalse(application.isApplying)
    }
}

@MainActor
private final class PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

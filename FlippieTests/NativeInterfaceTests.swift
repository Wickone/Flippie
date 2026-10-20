import XCTest
import SwiftUI
@testable import Flippie

@MainActor
final class NativeInterfaceTests: XCTestCase {
    private var data: Data { get throws { try Data(contentsOf: XCTUnwrap(Bundle(for: NativeInterfaceTests.self).url(forResource: "test_star", withExtension: "json"))) } }

    func testNativeLightTabsInterceptSheetCommandsWithoutReplacingPreview() async throws {
        let document = AnimationDocument()
        let session = PlaybackSession()
        let sheets = SheetCoordinator()
        try document.load(data: data)
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        let host = UIHostingController(rootView: ContentView(document: document, session: session, sheets: sheets)
            .environment(\.scenePhase, .active))
        let window = mount(host)
        window.overrideUserInterfaceStyle = .dark
        defer { session.close(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let tabs = try XCTUnwrap(findTabs(host), "Must use an actual UITabBarController, not an imitation")
        XCTAssertEqual(tabs.viewControllers?.count, 3)
        XCTAssertEqual(tabs.tabBar.items?.compactMap(\.title), ["Preview", "Edit", "Export"])
        XCTAssertEqual(tabs.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(tabs.tabBar.traitCollection.userInterfaceStyle, .light)
        let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pixel = try XCTUnwrap(screen.cgImage?.cropping(to: CGRect(x: 5 * screen.scale,
            y: window.bounds.height * 0.55 * screen.scale, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(Int(rgba[2]) - Int(rgba[0]), 100, "The native container must not replace the blue screen with white")
        let previewController = try XCTUnwrap(tabs.selectedViewController)
        let preview = session.player
        let engine = try XCTUnwrap(preview.subviews.first)
        session.loopMode = .loop
        session.setSceneActive(true)
        session.play()
        XCTAssertTrue(session.isPlaying, "Test must start with active playback")
        for index in [1, 2, 1, 2] {
            let command = try XCTUnwrap(tabs.viewControllers?[index])
            let shouldSelect = tabs.delegate?.tabBarController?(tabs, shouldSelect: command)
            XCTAssertEqual(shouldSelect, false)
            XCTAssertEqual(sheets.active?.id, index == 1 ? SheetRoute.edit.id : SheetRoute.export.id)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(tabs.selectedViewController === previewController)
            XCTAssertTrue(session.player === preview)
            XCTAssertTrue(preview.subviews.first === engine)
            XCTAssertNotNil(preview.window)
            XCTAssertTrue(session.isPlaying)
            sheets.dismiss()
            for _ in 0..<60 {
                if host.presentedViewController == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(host.presentedViewController)
        }
    }

    func testLandscapePreviewFitsInsideViewport() async throws {
        let document = AnimationDocument()
        let session = PlaybackSession()
        try document.load(data: data)
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        let host = UIHostingController(rootView: ContentView(document: document, session: session)
            .frame(width: 844, height: 390))
        let window = mount(host)
        defer { session.close(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let frame = session.player.convert(session.player.bounds, to: host.view)
        XCTAssertGreaterThan(frame.width, 100)
        XCTAssertGreaterThan(frame.height, 80)
        let viewport = CGRect(x: (host.view.bounds.width - 844) / 2,
                              y: (host.view.bounds.height - 390) / 2, width: 844, height: 390)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(frame), "Preview outside viewport: \(frame) / \(viewport)")
    }

    private func mount(_ host: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return window
    }

    func testNativeTabBarIsRaisedWithoutResizingOrMovingPreview() async throws {
        let standardTabs = UITabBarController()
        standardTabs.overrideUserInterfaceStyle = .light
        if #available(iOS 18.0, *) { standardTabs.mode = .tabBar }
        standardTabs.viewControllers = LoadedActionTab.allCases.map { tab in
            let controller = UIViewController()
            controller.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.systemName), tag: tab.rawValue)
            return controller
        }
        let window = mount(standardTabs)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let defaultBar = standardTabs.tabBar.convert(standardTabs.tabBar.bounds, to: window)
        let document = AnimationDocument()
        let session = PlaybackSession()
        try document.load(data: data)
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        defer { session.close() }
        let host = UIHostingController(rootView: ContentView(document: document, session: session).dynamicTypeSize(.large))
        window.rootViewController = host
        try await Task.sleep(for: .milliseconds(500))
        let tabs = try XCTUnwrap(findTabs(host))
        let raisedBar = tabs.tabBar.convert(tabs.tabBar.bounds, to: window)
        let expectedLift: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 0 : 40
        XCTAssertEqual(raisedBar.minY, defaultBar.minY - expectedLift, accuracy: 1)
        XCTAssertEqual(raisedBar.width, defaultBar.width, accuracy: 1)
        XCTAssertEqual(raisedBar.height, defaultBar.height, accuracy: 1, "Do not stretch the native bar or its glass")
        XCTAssertEqual(tabs.tabBar.traitCollection.userInterfaceStyle, .light)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let scale = window.bounds.width / 393
            let preview = session.player.convert(session.player.bounds, to: window)
            XCTAssertEqual(preview.minX, 16 + 22 * scale, accuracy: 1)
            XCTAssertEqual(preview.minY, 154 * scale, accuracy: 1)
            XCTAssertEqual(preview.width, window.bounds.width - 32 - 44 * scale, accuracy: 1)
            XCTAssertEqual(preview.height, 318 * scale, accuracy: 1)
        }
    }

    func testPhoneSupportsOnlyPortrait() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String],
                       ["UIInterfaceOrientationPortrait"])
    }

    func testRaisedBarKeepsHeightLimitedPortraitPreviewUnchanged() async throws {
        let document = AnimationDocument()
        let session = PlaybackSession()
        try document.load(data: data)
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        func page() -> LoadedPreviewScreen {
            LoadedPreviewScreen(document: document, session: session, onBack: {}, onProfile: {},
                                onSettings: {}, onPlay: {}, onPrevious: {}, onNext: {})
        }
        let reference = ZStack {
            FlippieScreenBackground().ignoresSafeArea()
            StandardTabsLayoutReference(preview: page()).ignoresSafeArea()
        }.frame(width: 375, height: 667)
        let host = UIHostingController(rootView: AnyView(reference))
        let window = mount(host)
        defer { session.close(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let before = session.player.convert(session.player.bounds, to: host.view)
        host.rootView = AnyView(ContentView(document: document, session: session).frame(width: 375, height: 667))
        try await Task.sleep(for: .milliseconds(300))
        let after = session.player.convert(session.player.bounds, to: host.view)
        XCTAssertEqual(after.minX, before.minX, accuracy: 1)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1)
        XCTAssertEqual(after.width, before.width, accuracy: 1)
        XCTAssertEqual(after.height, before.height, accuracy: 1, "Raising the bar must not shrink a height-limited portrait preview")
    }

    func testPreviewBoundsAtSupportedWidthsAndAccessibilitySize() async throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852),
                     CGSize(width: 430, height: 932), CGSize(width: 768, height: 1024),
                     CGSize(width: 844, height: 390), CGSize(width: 520, height: 320),
                     CGSize(width: 568, height: 320)] {
            for type in [DynamicTypeSize.large, .accessibility5] {
                let document = AnimationDocument()
                let session = PlaybackSession()
                try document.load(data: data)
                try await session.load(data: data, runtime: .v461, baseURL: nil)
                let host = UIHostingController(rootView: ContentView(document: document, session: session)
                    .dynamicTypeSize(type).frame(width: size.width, height: size.height))
                let window = mount(host)
                try await Task.sleep(for: .milliseconds(300))
                let frame = session.player.convert(session.player.bounds, to: host.view)
                let viewport = CGRect(x: (host.view.bounds.width - size.width) / 2,
                                      y: (host.view.bounds.height - size.height) / 2,
                                      width: size.width, height: size.height)
                XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(frame), "\(size) \(type): \(frame) / \(viewport)")
                XCTAssertGreaterThan(frame.height, 70)
                XCTAssertNotNil(findTabs(host))
                session.close()
                window.isHidden = true
            }
        }
    }

    func testReduceMotionKeepsDecorativeLogoStill() async throws {
        let host = UIHostingController(rootView: FlippieBlinkingLogo(size: 132, reduceMotionOverride: true))
        let window = mount(host)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        func pixels() -> Data? {
            UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }.pngData()
        }
        let original = pixels()
        for _ in 0..<105 {
            try await Task.sleep(for: .milliseconds(50))
            if pixels() != original { XCTFail("Reduce Motion must disable the decorative blink"); return }
        }
    }

    func testRotationKeepsMainThreadRendererPlayingAndAdvancing() async throws {
        let moving = Data("""
        {"v":"5.7.0","fr":60,"ip":0,"op":600,"w":100,"h":100,"layers":[
          {"ty":1,"ind":1,"ip":0,"op":600,"st":0,"sw":20,"sh":20,"sc":"#ff0000",
           "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},
           "p":{"a":1,"k":[{"t":0,"s":[10,50,0],"e":[90,50,0],"o":{"x":0.33,"y":0},"i":{"x":0.67,"y":1}},{"t":600,"s":[90,50,0]}]},
           "a":{"a":0,"k":[10,10,0]},"s":{"a":0,"k":[100,100,100]}}}]}
        """.utf8)
        let document = AnimationDocument()
        let session = PlaybackSession()
        try document.load(data: moving)
        try await session.load(data: moving, runtime: .v350, baseURL: nil)
        func content(_ size: CGSize) -> some View {
            ContentView(document: document, session: session)
                .environment(\.scenePhase, .active)
                .frame(width: size.width, height: size.height)
        }
        let host = UIHostingController(rootView: content(CGSize(width: 393, height: 852)))
        let window = mount(host)
        defer { session.close(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        session.setSceneActive(true)
        session.play()
        XCTAssertTrue(session.isPlaying)
        let engine = session.player.subviews.first
        for size in [CGSize(width: 844, height: 390), CGSize(width: 393, height: 852)] {
            host.rootView = content(size)
            try await Task.sleep(for: .milliseconds(300))
            let frame = session.currentFrame
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(session.isPlaying, "Rotation must not pause playback")
            XCTAssertEqual(session.readiness, .ready)
            XCTAssertTrue(session.player.subviews.first === engine)
            XCTAssertNotNil(session.player.window)
            XCTAssertGreaterThan(session.currentFrame, frame + 5, "Frames must continue advancing after rotation")
        }
    }

    func testTransientZeroWidthDoesNotProduceNegativePreviewHeight() {
        for width in [CGFloat(0), 16, 31] {
            XCTAssertGreaterThanOrEqual(LoadedPreviewScreen.previewHeight(
                in: CGSize(width: width, height: 568), wide: false, largeType: false), 0)
        }
    }

    func testLandingKeepsBlueBackgroundUnderNativeNavigation() async throws {
        for type in [DynamicTypeSize.large, .accessibility5] {
            let host = UIHostingController(rootView: ContentView(document: AnimationDocument(), session: PlaybackSession())
                .dynamicTypeSize(type))
            let window = mount(host)
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(300))
            let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let pixel = try XCTUnwrap(screen.cgImage?.cropping(to: CGRect(x: 5 * screen.scale,
                y: window.bounds.height * 0.4 * screen.scale, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(Int(rgba[2]) - Int(rgba[0]), 100,
                                 "Native navigation must not turn the landing screen white at \(type)")
        }
    }

    func testPortraitPreviewKeepsOriginalCardSizeAndPosition() async throws {
        let document = AnimationDocument()
        let session = PlaybackSession()
        try document.load(data: data)
        try await session.load(data: data, runtime: .v461, baseURL: nil)
        let host = UIHostingController(rootView: ContentView(document: document, session: session).dynamicTypeSize(.large))
        let window = mount(host)
        defer { session.close(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let scale = window.bounds.width / 393
        let frame = session.player.convert(session.player.bounds, to: window)
        XCTAssertEqual(frame.minX, 16 + 22 * scale, accuracy: 1)
        XCTAssertEqual(frame.minY, 154 * scale, accuracy: 1)
        XCTAssertEqual(frame.width, window.bounds.width - 32 - 44 * scale, accuracy: 1)
        XCTAssertEqual(frame.height, 318 * scale, accuracy: 1)
    }

    func testShortLandscapeStacksFullSizeControlsWhenTwoColumnsCannotFit() {
        for width in [CGFloat(520), 568] {
            XCTAssertFalse(LoadedPreviewScreen.usesSideBySideLayout(in: CGSize(width: width, height: 320)))
        }
        XCTAssertTrue(LoadedPreviewScreen.usesSideBySideLayout(in: CGSize(width: 844, height: 390)))
        XCTAssertTrue(LoadedPreviewScreen.usesSideBySideLayout(in: CGSize(width: 600, height: 320)))
    }

    func testGreetingTailHasOneTranslucentFillWithoutOverlapBand() async throws {
        let host = UIHostingController(rootView: AnyView(FlippieScreenBackground().ignoresSafeArea()))
        let window = mount(host)
        defer { window.isHidden = true }
        let scale = window.bounds.width / 393
        let point = CGPoint(x: 100 * scale, y: 246 * scale)
        func pixel() throws -> [UInt8] {
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let crop = try XCTUnwrap(screenshot.cgImage?.cropping(to: CGRect(x: point.x * screenshot.scale,
                y: point.y * screenshot.scale, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgba
        }
        try await Task.sleep(for: .milliseconds(300))
        let backdrop = try pixel()
        host.rootView = AnyView(ContentView(document: AnimationDocument(), session: PlaybackSession()).dynamicTypeSize(.large))
        try await Task.sleep(for: .milliseconds(300))
        let actual = try pixel()
        for channel in 0..<3 {
            let singleFill = Double(backdrop[channel]) * 0.92 + 255 * 0.08
            XCTAssertEqual(Double(actual[channel]), singleFill, accuracy: 4,
                           "The tail/body intersection must be drawn once at 8 percent opacity")
        }
    }

    private func findTabs(_ root: UIViewController) -> UITabBarController? {
        if let tabs = root as? UITabBarController { return tabs }
        for child in root.children { if let tabs = findTabs(child) { return tabs } }
        return nil
    }
}

private struct StandardTabsLayoutReference<Preview: View>: UIViewControllerRepresentable {
    let preview: Preview
    func makeUIViewController(context: Context) -> NativePreviewTabController<Preview> {
        NativePreviewTabController(preview: preview, onCommand: { _ in })
    }
    func updateUIViewController(_ controller: NativePreviewTabController<Preview>, context: Context) {
        controller.previewHost.rootView = preview
    }
}

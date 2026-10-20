import XCTest
import WebKit
@testable import Flippie

@MainActor
final class WebRendererTests: XCTestCase {
    func testWebSnapshotCancellationFinishes() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let web = browser(player)
        _ = try await js(web, "window.captureLottieSnapshot=function(id){window.testSnapshotID=id;}; true;")
        var finished = false
        var resultError: Error?
        let task = Task { @MainActor in
            do { _ = try await player.snapshotCGImage(size: CGSize(width: 100, height: 100)) }
            catch { resultError = error }
            finished = true
        }
        _ = await eventually { (try? await js(web, "!!window.testSnapshotID")) as? Bool == true }
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(finished, "Cancelled snapshot must finish without a JS reply")
        XCTAssertTrue(resultError is CancellationError)
        if !finished { try await releaseSnapshot(web) }
        await task.value
    }

    func testReadyFailureIsReturnedToLateWaiter() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        player.webView(browser(player), didFail: nil, withError: NSError(domain: "test-navigation", code: 17))
        do { try await player.waitForPlaybackReadiness(); XCTFail("Failed readiness must stay failed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("17")) }
    }

    func testWebProcessTerminationFailsPendingRequests() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let web = browser(player)
        _ = try await js(web, "window.captureLottieSnapshot=function(id){window.testSnapshotID=id;};window.prepareLottieFrame=function(){};true;")
        var finished = false
        var frameFinished = false
        let frame = Task { @MainActor in
            do { try await player.prepareFrame(progress: 0.5); XCTFail("Terminated renderer cannot prepare a frame") }
            catch { }
            frameFinished = true
        }
        let task = Task { @MainActor in
            do { _ = try await player.snapshotCGImage(size: CGSize(width: 100, height: 100)); XCTFail("Terminated renderer cannot return an image") }
            catch { }
            finished = true
        }
        _ = await eventually { (try? await js(web, "!!window.testSnapshotID")) as? Bool == true }
        player.webViewWebContentProcessDidTerminate(web)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(finished, "Process termination must finish every pending request")
        XCTAssertTrue(frameFinished)
        XCTAssertEqual(player.pendingRequestCount, 0)
        if !finished { try await releaseSnapshot(web) }
        await task.value
        await frame.value
    }

    func testUnicodeIsActualRenderedTextLayerContent() async throws {
        let (player, window) = try await makePlayer(text: "Привет 👋")
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let text = try await js(browser(player), "Array.from(document.querySelectorAll('#animation svg text')).filter(function(n){return !n.closest('defs');}).map(function(n){return n.textContent;}).join('')") as? String
        XCTAssertEqual(text, "Привет 👋")
    }

    func testWebAutoReverseVisitsFramesInBothDirections() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let web = browser(player)
        _ = try await js(web, "window.testFrames=[];window.flippiePlayer.addEventListener('enterFrame',function(e){window.testFrames.push(e.currentTime);}); true;")
        player.setLoopMode(.autoReverse)
        player.setSpeed(3)
        player.play()
        try await Task.sleep(for: .milliseconds(1100))
        player.pause()
        let frames = try await js(web, "window.testFrames") as? [Double] ?? []
        let changes = zip(frames, frames.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(changes.contains { $0 > 0.1 && $0 < 20 })
        XCTAssertGreaterThan(changes.filter { $0 < -0.1 && $0 > -20 }.count, 3, "A wrap jump is not reverse playback")
    }

    private func makePlayer(text: String? = nil) async throws -> (LottieWebPlayerView, UIWindow) {
        let player = LottieWebPlayerView()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController!.view.addSubview(player)
        player.frame = CGRect(x: 0, y: 100, width: 200, height: 200)
        window.makeKeyAndVisible()
        _ = try player.load(data: Stage4Fixture.animation(blur: true, text: text))
        try await player.waitForPlaybackReadiness()
        return (player, window)
    }

    func testRealWebSnapshotContainsPreparedObject() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        try await player.prepareFrame(progress: 0.5)
        let image = try await player.snapshotCGImage(size: CGSize(width: 100, height: 100))
        XCTAssertEqual(try Stage4Fixture.redCenter(image), 50, accuracy: 3)
    }

    func testFrameRequestsCancelAndTimeOutWithoutDrawReply() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let web = browser(player)
        _ = try await js(web, "window.prepareLottieFrame=function(id){window.testFrameID=id;};true;")
        var cancelled = false
        let task = Task { @MainActor in
            do { try await player.prepareFrame(progress: 0.5); XCTFail("Cancelled frame must not succeed") }
            catch is CancellationError { cancelled = true }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        let registered = await eventually { player.pendingRequestCount == 1 }
        XCTAssertTrue(registered)
        task.cancel()
        await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(player.pendingRequestCount, 0)
        player.requestTimeout = .milliseconds(100)
        do { try await player.prepareFrame(progress: 0.75); XCTFail("Missing drawnFrame must time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("frame")) }
        XCTAssertEqual(player.pendingRequestCount, 0)
    }

    func testAsyncJavaScriptErrorsPersistAsReadinessFailure() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        _ = try await js(browser(player), "setTimeout(function(){throw new Error('async-render-failure');},0);true;")
        try await Task.sleep(for: .milliseconds(80))
        do { try await player.waitForPlaybackReadiness(); XCTFail("Async renderer failure must persist") }
        catch {
            guard case LottieWebPlayerError.loadFailed(let message) = error else {
                return XCTFail("Expected bridged JavaScript failure, got \(error)")
            }
            XCTAssertFalse(message.isEmpty) // WebKit may redact this to “Script error.”
            do { try await player.waitForPlaybackReadiness(); XCTFail("Late waiter must see the same failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains(message)) }
        }
    }

    func testSupersededPageCancelsRequestsAndIgnoresOldMessages() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let web = browser(player)
        let oldValue = try await js(web, "window.flippieGeneration")
        let oldGeneration = try XCTUnwrap(oldValue as? String)
        _ = try await js(web, "window.captureLottieSnapshot=function(id){window.testSnapshotID=id;};true;")
        var cancelled = false
        let old = Task { @MainActor in
            do { _ = try await player.snapshotCGImage(size: CGSize(width: 100, height: 100)); XCTFail("Superseded snapshot must not succeed") }
            catch is CancellationError { cancelled = true }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        let registered = await eventually { player.pendingRequestCount == 1 }
        XCTAssertTrue(registered)
        _ = try player.load(data: Stage4Fixture.animation(blur: true))
        await old.value
        XCTAssertTrue(cancelled)
        try await player.waitForPlaybackReadiness()
        _ = try await js(web, "window.webkit.messageHandlers.flippie.postMessage({generation:'\(oldGeneration)',type:'frame',frame:999});true;")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(player.currentFrame, 60, accuracy: 0.01)
        XCTAssertEqual(player.pendingRequestCount, 0)
    }

    func testRendererFailureStopsSessionPolling() async throws {
        let session = PlaybackSession()
        try await session.load(data: Stage4Fixture.animation(blur: true), runtime: .v461, baseURL: nil)
        defer { session.close() }
        session.play()
        XCTAssertTrue(session.isTrackingProgress)
        let webPlayer = try XCTUnwrap(session.player.subviews.compactMap { $0 as? LottieWebPlayerView }.first)
        webPlayer.webViewWebContentProcessDidTerminate(browser(webPlayer))
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isTrackingProgress)
        XCTAssertEqual(session.readiness, .failed)
    }

    func testRendererErrorCannotBeAcknowledgedAsPreparedFrame() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        _ = try await js(browser(player), "window.flippiePlayer.renderer.renderFrame=function(){throw new Error('renderer-failure');};true;")
        do { try await player.prepareFrame(progress: 0.5); XCTFail("drawnFrame after renderer error must not succeed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("renderer-failure")) }
        XCTAssertEqual(player.pendingRequestCount, 0)
    }

    func testTerminalFailurePausesJSAndReleasesSnapshotResources() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let web = browser(player)
        _ = try await js(web, "window.testRevoked=[];window.testRevoke=URL.revokeObjectURL;URL.revokeObjectURL=function(url){window.testRevoked.push(url);window.testRevoke.call(URL,url);};window.Image=function(){return {onload:null,onerror:null,set src(value){}};};true;")
        player.play()
        var finished = false
        let snapshot = Task { @MainActor in
            do { _ = try await player.snapshotCGImage(size: CGSize(width: 100, height: 100)); XCTFail("Failed renderer cannot return a pending image") }
            catch { }
            finished = true
        }
        let allocated = await eventually { (try? await self.js(web, "window.testRevoked.length===0 && window.flippiePlayer.isPaused===false")) as? Bool == true && player.pendingRequestCount == 1 }
        XCTAssertTrue(allocated)
        // JS queue barrier ensures captureLottieSnapshot allocated its blob URL.
        _ = try await js(web, "true")
        player.webView(web, didFail: nil, withError: NSError(domain: "test-terminal", code: 1))
        await snapshot.value
        XCTAssertTrue(finished)
        let paused = try await js(web, "window.flippiePlayer.isPaused") as? Bool
        let revoked = try await js(web, "window.testRevoked.length") as? Int
        XCTAssertEqual(paused, true)
        XCTAssertEqual(revoked, 1)
        XCTAssertEqual(player.pendingRequestCount, 0)
    }

    func testReadinessResolutionRechecksFailureAndPageGeneration() async throws {
        for supersede in [false, true] {
            let player = LottieWebPlayerView()
            let web = browser(player)
            web.configuration.userContentController.addUserScript(WKUserScript(source:
                "window.webkit.messageHandlers.flippie.postMessage=function(){};",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            _ = try player.load(data: Stage4Fixture.animation(blur: true))
            let initialized = await eventually { (try? await self.js(web, "typeof window.flippieGeneration==='string'")) as? Bool == true }
            XCTAssertTrue(initialized)
            let value = try await js(web, "window.flippieGeneration")
            let epoch = try XCTUnwrap(value as? String)
            var failed = false
            let ready = Task { @MainActor in
                do { try await player.waitForPlaybackReadiness(); XCTFail("Resolved readiness must be revalidated before returning") }
                catch is CancellationError { XCTAssertTrue(supersede); failed = true }
                catch { XCTAssertFalse(supersede); failed = true }
            }
            let registered = await eventually { player.pendingRequestCount == 1 }
            XCTAssertTrue(registered)
            player.receive(["generation": epoch, "type": "ready"])
            // No suspension between resolve and invalidation: deterministic race.
            if supersede { _ = try player.load(data: Stage4Fixture.animation(blur: true)) }
            else { player.webViewWebContentProcessDidTerminate(web) }
            await ready.value
            XCTAssertTrue(failed)
            player.invalidate()
        }
    }

    func testFractionalFrameBoundsMatchActualWebSegment() async throws {
        for (start, end) in [(60.0, 120.5), (60.75, 120.25)] {
            let player = LottieWebPlayerView()
            player.requestTimeout = .milliseconds(600)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Stage4Fixture.animation(blur: true)) as? [String: Any])
            root["ip"] = start
            root["op"] = end
            _ = try player.load(data: JSONSerialization.data(withJSONObject: root))
            try await player.waitForPlaybackReadiness()
            let first = try await js(browser(player), "window.flippiePlayer.firstFrame") as? Double
            XCTAssertEqual(try XCTUnwrap(first), start, accuracy: 0.001)
            try await player.prepareFrame(progress: 0.5)
            XCTAssertEqual(player.currentFrame, (start + end) / 2, accuracy: 0.001)
            try await player.prepareFrame(progress: 1)
            XCTAssertEqual(player.currentFrame, end - 0.001, accuracy: 0.001)
            player.invalidate()
        }
    }

    func testFailedReplacementPreservesFailedReadiness() async throws {
        let session = PlaybackSession()
        try await session.load(data: Stage4Fixture.animation(blur: true), runtime: .v461, baseURL: nil)
        defer { session.close() }
        session.play()
        let webPlayer = try XCTUnwrap(session.player.subviews.compactMap { $0 as? LottieWebPlayerView }.first)
        webPlayer.webViewWebContentProcessDidTerminate(browser(webPlayer))
        XCTAssertEqual(session.readiness, .failed)
        do { try await session.load(data: Data("{}".utf8), runtime: .v461, baseURL: nil); XCTFail("Invalid replacement must fail") }
        catch { }
        XCTAssertEqual(session.readiness, .failed)
    }

    func testSnapshotDeadlineFinishesAndRemovesRequest() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        player.requestTimeout = .milliseconds(120)
        let web = browser(player)
        _ = try await js(web, "window.captureLottieSnapshot=function(id){window.testSnapshotID=id;}; true;")
        var finished = false
        let task = Task { @MainActor in
            do { _ = try await player.snapshotCGImage(size: CGSize(width: 100, height: 100)); XCTFail("Missing reply must time out") }
            catch { }
            finished = true
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(finished)
        XCTAssertEqual(player.pendingRequestCount, 0)
        if !finished { try await releaseSnapshot(web) }
        await task.value
    }

    func testPreparedFrameWaitsForDrawAcknowledgement() async throws {
        let (player, window) = try await makePlayer()
        defer { player.stop(); player.removeFromSuperview(); window.isHidden = true }
        let web = browser(player)
        _ = try await js(web, "window.prepareLottieFrame=function(id,frame){setTimeout(function(){window.setLottieFrame(frame);window.testFrameAck=true;window.postFlippie({type:'frameReady',id:id,frame:frame});},250);}; true;")
        try await player.prepareFrame(progress: 0.5)
        let acknowledged = (try await js(web, "window.testFrameAck === true")) as? Bool
        XCTAssertEqual(acknowledged, true, "Elapsed time is not a renderer acknowledgement")
        XCTAssertEqual(player.currentFrame, 90, accuracy: 0.01)
    }

    func testReadyCancellationAndDeadlineFinishWithoutRendererReply() async throws {
        let player = LottieWebPlayerView()
        let web = browser(player)
        web.configuration.userContentController.addUserScript(WKUserScript(source:
            "window.testOriginalPost=window.webkit.messageHandlers.flippie.postMessage.bind(window.webkit.messageHandlers.flippie);window.webkit.messageHandlers.flippie.postMessage=function(){};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        _ = try player.load(data: Stage4Fixture.animation(blur: true))
        player.requestTimeout = .milliseconds(120)
        var cancelledFinished = false
        var cancelError: Error?
        let cancelled = Task { @MainActor in
            do { _ = try await player.snapshotCGImage(size: CGSize(width: 100, height: 100)) }
            catch { cancelError = error }
            cancelledFinished = true
        }
        var timeoutFinished = false
        let timed = Task { @MainActor in
            do { try await player.waitForPlaybackReadiness(); XCTFail("Missing readiness must time out") }
            catch { }
            timeoutFinished = true
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(cancelledFinished)
        XCTAssertTrue(cancelError is CancellationError)
        XCTAssertTrue(timeoutFinished)
        XCTAssertEqual(player.pendingRequestCount, 0)
        // Release the old implementation's unbounded waiter so RED terminates.
        if !cancelledFinished || !timeoutFinished {
            _ = try await js(web, "window.captureLottieSnapshot=function(){throw new Error('Test cleanup');};window.webkit.messageHandlers.flippie.postMessage=window.testOriginalPost;window.testOriginalPost({generation:window.flippieGeneration,type:'ready',totalFrames:60});true;")
        }
        await cancelled.value
        await timed.value
        player.stop()
    }

    private func browser(_ player: LottieWebPlayerView) -> WKWebView { player.subviews.compactMap { $0 as? WKWebView }.first! }

    private func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source) { value, error in
                if let error {
                    print("TEST JS ERROR: \((error as NSError).domain) \((error as NSError).code) \(error)")
                    continuation.resume(throwing: error)
                }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func releaseSnapshot(_ web: WKWebView) async throws {
        _ = try await js(web, "window.webkit.messageHandlers.flippie.postMessage({generation:window.flippieGeneration,type:'snapshotError',id:window.testSnapshotID,message:'Test cleanup'});")
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return false
    }
}

@MainActor
enum Stage4Fixture {
    static func animation(blur: Bool, mask: Bool = false, text: String? = nil) throws -> Data {
        let transform: [String: Any] = [
            "o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0],
            "p": ["a": 1, "k": [
                ["t": 60, "s": [20, 50, 0], "e": [80, 50, 0], "o": ["x": 0, "y": 0], "i": ["x": 1, "y": 1]],
                ["t": 120, "s": [80, 50, 0]],
            ]], "a": ["a": 0, "k": [10, 10, 0]], "s": ["a": 0, "k": [100, 100, 100]],
        ]
        var layer: [String: Any] = [
            "ddd": 0, "ind": 1, "ty": 1, "nm": "Moving square", "sr": 1, "ks": transform,
            "sw": 20, "sh": 20, "sc": "#ff3311", "ip": 60, "op": 120, "st": 0, "bm": 0,
        ]
        if blur {
            layer["ef"] = [["ty": 29, "nm": "Gaussian Blur", "ef": [
                ["ty": 0, "v": ["a": 0, "k": 4]], ["ty": 7, "v": ["a": 0, "k": 1]], ["ty": 7, "v": ["a": 0, "k": 0]],
            ]]]
        }
        if mask {
            layer["hasMask"] = true
            layer["masksProperties"] = [["inv": false, "mode": "a", "cl": true, "nm": "Left-half mask",
                "x": ["a": 0, "k": 0], "o": ["a": 0, "k": 100],
                "pt": ["a": 0, "k": ["c": true, "v": [[0, 0], [10, 0], [10, 20], [0, 20]],
                    "i": [[0, 0], [0, 0], [0, 0], [0, 0]], "o": [[0, 0], [0, 0], [0, 0], [0, 0]]]],
            ]]
        }
        var root: [String: Any] = ["v": "5.7.0", "fr": 60, "ip": 60, "op": 120, "w": 100, "h": 100, "layers": [layer], "assets": []]
        if let text {
            layer["ty"] = 5
            layer["t"] = ["d": ["k": [["t": 60, "s": ["t": text, "f": "ArialMT", "s": 14, "fc": [1, 0, 0], "j": 0, "tr": 0, "lh": 18, "ls": 0]]]], "p": [:], "m": ["g": 1, "a": ["a": 0, "k": [0, 0]]], "a": []]
            root["layers"] = [layer]
            root["fonts"] = ["list": [["fName": "ArialMT", "fFamily": "Arial", "fStyle": "Regular", "ascent": 75]]]
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func redCenter(_ image: CGImage) throws -> Double {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var total = 0.0, weighted = 0.0
        for y in 0..<height { for x in 0..<width {
            let pixel = data.advanced(by: (y * width + x) * 4)
            if pixel[0] > 30 && Int(pixel[0]) > Int(pixel[1]) * 2 && pixel[3] > 20 {
                let weight = Double(pixel[3])
                total += weight
                weighted += (Double(x) + 0.5) * weight
            }
        } }
        XCTAssertGreaterThan(total, 0, "Rendered image must contain the moving object")
        return total > 0 ? weighted / total : -1
    }
}

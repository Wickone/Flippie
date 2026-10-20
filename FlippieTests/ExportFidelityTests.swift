import XCTest
import AVFoundation
import ImageIO
import UIKit
@testable import Flippie

@MainActor
final class ExportFidelityTests: XCTestCase {
    // The expected centers are derived from x = 16 + 96 * time / 1.01,
    // not from the exporter's frame-count/progress helpers.
    func testMP4FractionalDurationHasCorrectDecodedPositionsAndTimestamps() async throws {
        let url = try await AnimationExporter().export(request: request(.mp4)) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try await decodeVideo(url)
        XCTAssertEqual(frames.count, 31)
        for (index, expectedX) in [(0, 16.0), (15, 63.52), (30, 111.05)] {
            XCTAssertEqual(frames[index].time, Double(index) / 30, accuracy: 0.0001)
            XCTAssertEqual(try redCenter(frames[index].image), expectedX, accuracy: 0.8)
        }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 31.0 / 30, accuracy: 0.001)
        XCTAssertEqual(frames[0].image.width, 128)
        XCTAssertEqual(frames[0].image.height, 64)
        let corner = pixel(frames[0].image, x: 0, y: 0)
        XCTAssertGreaterThan(corner[2], 220) // blue background
        XCTAssertLessThan(corner[0], 30)
        for (index, x) in [(0, 16), (15, 64), (30, 111)] {
            let cyan = pixel(frames[index].image, x: x, y: 16)
            let attachment = XCTAttachment(image: UIImage(cgImage: frames[index].image))
            attachment.name = "decoded-mp4-\(index)"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertLessThan(cyan[0], 45)
            XCTAssertGreaterThan(cyan[1], 200)
            XCTAssertGreaterThan(cyan[2], 200)
        }
    }

    func testGIFDecodedPositionsTransparencyAndAccumulatedDelay() async throws {
        let url = try await AnimationExporter().export(request: request(.gif, transparent: true)) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 31)
        var total = 0.0
        for index in 0..<31 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            total += try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        }
        XCTAssertEqual(total, 1.03, accuracy: 0.001)
        for (index, expectedX) in [(0, 16.0), (15, 63.52), (30, 111.05)] {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(try redCenter(image), expectedX, accuracy: 0.8)
            XCTAssertEqual(pixel(image, x: 0, y: 0)[3], 0)
            let cyan = pixel(image, x: Int(expectedX.rounded()), y: 16)
            XCTAssertGreaterThan(cyan[1], 240)
            XCTAssertGreaterThan(cyan[2], 240)
        }
    }

    func testJSONEmbedsImagesAndRendersWithoutOriginalFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).pngData { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try png.write(to: directory.appendingPathComponent("image.png"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: animation()) as? [String: Any])
        root["assets"] = [["id": "image", "w": 16, "h": 16, "u": "", "p": "image.png", "e": 0]]
        root["layers"] = [["ddd": 0, "ind": 1, "ty": 2, "refId": "image", "sr": 1,
                            "ks": transform(position: [16, 16, 0]), "ip": 60, "op": 161, "st": 0]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let base = request(.json)
        let url = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: data, runtime: .v461, plan: base.plan, assetBaseURL: directory
        )) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.removeItem(at: directory)
        let exported = try Data(contentsOf: url)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let assets = try XCTUnwrap(result["assets"] as? [[String: Any]])
        XCTAssertTrue((assets[0]["p"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        let renderer = try AnimationFrameRenderer(animationData: exported, runtime: .v461,
            size: CGSize(width: 128, height: 64), transparent: true,
            backgroundColor: RGBAColor(red: 0, green: 0, blue: 0))
        let image = try await renderer.render(progress: 0, frameIndex: 0)
        XCTAssertGreaterThan(pixel(image, x: 24, y: 24)[0], 240)
        XCTAssertGreaterThan(pixel(image, x: 24, y: 24)[3], 240)
    }

    func testJSONWithMissingImageFailsInsteadOfExportingBrokenFile() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: animation()) as? [String: Any])
        root["assets"] = [["id": "missing", "w": 16, "h": 16, "u": "", "p": "absent.png", "e": 0]]
        let base = request(.json)
        do {
            let url = try await AnimationExporter().export(request: AnimationExportRequest(
                animationData: JSONSerialization.data(withJSONObject: root), runtime: .v461, plan: base.plan
            )) { _ in }
            try? FileManager.default.removeItem(at: url)
            XCTFail("A JSON that needs unavailable images is not self-contained")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testPreflightRejectsNonFiniteAndExcessiveWorkBeforeAllocation() {
        for (size, fps, duration) in [(CGSize(width: CGFloat.infinity, height: 10), 30, 1.0),
            (CGSize(width: 100_000, height: 100_000), 30, 1.0),
            (CGSize(width: 16, height: 16), Int.max, 1.0),
            (CGSize(width: 16, height: 16), 30, Double.nan),
            (CGSize(width: 16, height: 16), 30, Double.infinity),
            (CGSize(width: 16, height: 16), 30, 100_000.0)] {
            let plan = AnimationExportPlan(format: .mp4, size: size, framesPerSecond: fps,
                duration: duration, transparent: false,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0), gifQuality: 1)
            XCTAssertThrowsError(try plan.validate())
        }
    }

    func testExportUsesTemporaryStorageNotUserDocuments() async throws {
        let url = try await AnimationExporter().export(request: request(.json)) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
    }

    func testEditorReplacementSurvivesDecodedGIF() async throws {
        let edits = AnimationEdits(colorReplacements: [
            RGBAColor(red: 1, green: 0, blue: 0): RGBAColor(red: 0, green: 1, blue: 0)])
        let base = request(.gif)
        let data = try AnimationDocument.renderedData(from: animation(), edits: edits)
        let url = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: data, runtime: .v461, plan: base.plan)) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let center = pixel(image, x: 16, y: 32)
        XCTAssertGreaterThan(center[1], 240)
        XCTAssertLessThan(center[0], 10)
    }

    func testTransparentMOVAdvertisesAlphaAndDecodedPixelsPreserveIt() async throws {
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: 128, AVVideoHeightKey: 64]
        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let probe = try AVAssetWriter(outputURL: probeURL, fileType: .mov)
        defer { try? FileManager.default.removeItem(at: probeURL) }
        guard probe.canApply(outputSettings: settings, forMediaType: .video) else {
            do {
                let url = try await AnimationExporter().export(request: request(.mov, transparent: true)) { _ in }
                ExportFileStore.remove(url); XCTFail("Unsupported alpha encoder must not silently produce an opaque MOV")
            } catch AnimationExportError.alphaEncodingUnavailable { }
            throw XCTSkip("AVAssetWriter reports HEVC with Alpha unsupported on this simulator")
        }
        let url = try await AnimationExporter().export(request: request(.mov, transparent: true)) { _ in }
        defer { ExportFileStore.remove(url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaCharacteristic: .containsAlphaChannel)
        XCTAssertEqual(tracks.count, 1)
        let frames = try await decodeVideo(url)
        for index in [0, 15, 30] {
            XCTAssertEqual(pixel(frames[index].image, x: 0, y: 0)[3], 0)
            let x = Int(try redCenter(frames[index].image))
            XCTAssertGreaterThan(pixel(frames[index].image, x: x, y: 32)[3], 245)
            let decoded = bytes(frames[index].image)
            let alpha = stride(from: 3, to: decoded.count, by: 4).map { decoded[$0] }
            XCTAssertTrue(alpha.contains { $0 > 10 && $0 < 240 }, "Rounded edges should retain partial alpha")
        }
    }

    func testCancellationDuringRenderingAndFinalizingDeletesOutput() async throws {
        for phase in [AnimationExportPhase.rendering, .finalizing] {
            try ExportFileStore.prepare()
            let before = try Set(FileManager.default.contentsOfDirectory(atPath: ExportFileStore.directory.path))
            let task = Task { @MainActor in
                try await AnimationExporter().export(request: self.request(.mp4), phase: { value in
                    if value == phase { withUnsafeCurrentTask { $0?.cancel() } }
                }) { _ in }
            }
            do { _ = try await task.value; XCTFail("Expected cancellation during \(phase)") }
            catch is CancellationError { }
            let after = try Set(FileManager.default.contentsOfDirectory(atPath: ExportFileStore.directory.path))
            XCTAssertEqual(after, before)
        }
    }

    func testWriterWaitHasDeadlineAndPropagatesFailure() async throws {
        do {
            try await ExportWriterWait.untilReady(timeout: .milliseconds(10), ready: { false }, failure: { nil })
            XCTFail("Stalled writer must have a deadline")
        } catch AnimationExportError.writerTimedOut { }
        do {
            try await ExportWriterWait.untilReady(ready: { false }, failure: {
                AnimationExportError.frameAppendFailed(2, "encoder failed")
            })
            XCTFail("A failed writer must stop waiting")
        } catch AnimationExportError.frameAppendFailed(let index, _) { XCTAssertEqual(index, 2) }
    }

    func testCancellationWhileWriterWaits() async throws {
        let task = Task {
            try await ExportWriterWait.untilReady(ready: { false }, failure: { nil })
        }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        do { try await task.value; XCTFail("Expected cancellation while waiting") }
        catch is CancellationError { }
    }

    func testFinalizeDeadlineAndCancellationIgnoreLateCallback() async throws {
        // A late completion (or a lost one in production) must not hold the export open.
        let start: @Sendable (@escaping @Sendable () -> Void) -> Void = { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { completion(); completion() }
        }
        do {
            try await ExportFinishWait.run(timeout: .milliseconds(10), start: start, cancel: {})
            XCTFail("Expected finalize deadline")
        } catch AnimationExportError.writerTimedOut { }
        let task = Task { try await ExportFinishWait.run(start: start, cancel: {}) }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        do { try await task.value; XCTFail("Expected finalize cancellation") }
        catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(70))
    }

    func testGIFQuantizationIsNotControlledByLossyQuality() async throws {
        let imageFormat = UIGraphicsImageRendererFormat(); imageFormat.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 64), format: imageFormat).pngData { context in
            for y in 0..<64 { for x in 0..<512 {
                UIColor(red: CGFloat(x) / 511, green: CGFloat(y) / 63,
                        blue: CGFloat((x + y) % 128) / 127, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }}
        }
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: animation()) as? [String: Any])
        root["w"] = 512
        root["assets"] = [["id": "gradient", "w": 512, "h": 64, "u": "", "e": 1,
                           "p": "data:image/png;base64," + png.base64EncodedString()]]
        root["layers"] = [["ddd": 0, "ind": 1, "ty": 2, "refId": "gradient", "sr": 1,
                            "ks": transform(position: [0, 0, 0]), "ip": 60, "op": 161, "st": 0]]
        let data = try JSONSerialization.data(withJSONObject: root)
        var results: [Data] = []
        for quality in [0.3, 1.0] {
            let base = request(.gif, transparent: true)
            let plan = AnimationExportPlan(format: .gif, size: CGSize(width: 512, height: 64), framesPerSecond: 30,
                duration: 0.1, transparent: true, backgroundColor: base.plan.backgroundColor, gifQuality: quality)
            let url = try await AnimationExporter().export(request: AnimationExportRequest(
                animationData: data, runtime: base.runtime, plan: plan)) { _ in }
            defer { ExportFileStore.remove(url) }
            results.append(try Data(contentsOf: url))
        }
        XCTAssertEqual(results[0], results[1], "Do not expose a JPEG-style quality slider for ImageIO GIF")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(results[0] as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = bytes(decoded)
        let colors = Set(stride(from: 0, to: pixels.count, by: 4).map {
            UInt32(pixels[$0]) << 24 | UInt32(pixels[$0+1]) << 16 | UInt32(pixels[$0+2]) << 8 | UInt32(pixels[$0+3])
        })
        XCTAssertLessThanOrEqual(colors.count, 256)
        XCTAssertGreaterThan(colors.count, 100, "The color-rich fixture must actually exercise palette quantization")
    }

    func testTemporaryStoreSweepsOnlyExpiredExports() throws {
        try ExportFileStore.prepare()
        let stale = ExportFileStore.directory.appendingPathComponent(UUID().uuidString + ".json")
        let fresh = ExportFileStore.directory.appendingPathComponent(UUID().uuidString + ".json")
        defer { ExportFileStore.remove(stale); ExportFileStore.remove(fresh) }
        try Data("old".utf8).write(to: stale); try Data("new".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: stale.path)
        try ExportFileStore.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        ExportFileStore.remove(fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testFinalizeTimeoutWinsOverCompletionInvokedByCancellation() async throws {
        let callback = ExportTestCallback()
        do {
            try await ExportFinishWait.run(timeout: .milliseconds(10), start: { completion in
                callback.set(completion)
            }, cancel: { callback.call() })
            XCTFail("Cancelling a stuck writer must not turn a timeout into success")
        } catch AnimationExportError.writerTimedOut { }
    }

    func testCancellationAfterEncodedFrameRemovesPartialGIFAndVideo() async throws {
        for format in [AnimationExportFormat.gif, .mp4] {
            try ExportFileStore.prepare()
            let before = try Set(FileManager.default.contentsOfDirectory(atPath: ExportFileStore.directory.path))
            var rendered = false
            let task = Task { @MainActor in
                try await AnimationExporter().export(request: self.request(format)) { progress in
                    if progress > 0 && progress < 1 {
                        rendered = true
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            do { _ = try await task.value; XCTFail("Expected cancellation after first frame") }
            catch is CancellationError { }
            XCTAssertTrue(rendered)
            let after = try Set(FileManager.default.contentsOfDirectory(atPath: ExportFileStore.directory.path))
            XCTAssertEqual(before, after)
        }
    }

    func testWebRasterExportIncludesExternalImagePixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).pngData { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try png.write(to: directory.appendingPathComponent("sprite.png"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: animation()) as? [String: Any])
        root["assets"] = [["id": "sprite", "w": 16, "h": 16, "u": "", "p": "sprite.png", "e": 0]]
        root["layers"] = [["ddd": 0, "ind": 1, "ty": 2, "refId": "sprite", "sr": 1,
            "ks": transform(position: [48, 24, 0]), "ip": 60, "op": 161, "st": 0,
            "ef": [["ty": 29, "nm": "Gaussian Blur", "ef": [
                ["ty": 0, "v": ["a": 0, "k": 1]], ["ty": 7, "v": ["a": 0, "k": 1]],
                ["ty": 7, "v": ["a": 0, "k": 0]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let plan = AnimationExportPlan(format: .gif, size: CGSize(width: 128, height: 64),
            framesPerSecond: 10, duration: 0.1, transparent: true,
            backgroundColor: RGBAColor(red: 0, green: 0, blue: 0), gifQuality: 1)
        let url = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: data, runtime: .v461, plan: plan, assetBaseURL: directory)) { _ in }
        defer { ExportFileStore.remove(url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThan(pixel(image, x: 56, y: 32)[0], 230)
        XCTAssertGreaterThan(pixel(image, x: 56, y: 32)[3], 240)
    }

    func testAlreadyEmbeddedImageWithStaleFlagsStillExportsThroughWeb() async throws {
        let imageFormat = UIGraphicsImageRendererFormat(); imageFormat.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: imageFormat).pngData { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: animation()) as? [String: Any])
        root["assets"] = [["id": "sprite", "w": 16, "h": 16, "u": "images/", "e": 0,
                           "p": "data:image/png;base64," + png.base64EncodedString()]]
        root["layers"] = [["ddd": 0, "ind": 1, "ty": 2, "refId": "sprite", "sr": 1,
            "ks": transform(position: [48, 24, 0]), "ip": 60, "op": 161, "st": 0,
            "ef": [["ty": 29, "nm": "Gaussian Blur", "ef": [
                ["ty": 0, "v": ["a": 0, "k": 1]], ["ty": 7, "v": ["a": 0, "k": 1]],
                ["ty": 7, "v": ["a": 0, "k": 0]]]]]]]
        let base = request(.json)
        let json = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: JSONSerialization.data(withJSONObject: root), runtime: .v461, plan: base.plan)) { _ in }
        defer { ExportFileStore.remove(json) }
        let plan = AnimationExportPlan(format: .gif, size: CGSize(width: 128, height: 64),
            framesPerSecond: 10, duration: 0.1, transparent: true,
            backgroundColor: RGBAColor(red: 0, green: 0, blue: 0), gifQuality: 1)
        let gif = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: Data(contentsOf: json), runtime: .v461, plan: plan)) { _ in }
        defer { ExportFileStore.remove(gif) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThan(pixel(image, x: 56, y: 32)[0], 230)
        XCTAssertGreaterThan(pixel(image, x: 56, y: 32)[3], 240)
    }

    func testUnusedExternalFontDoesNotBlockSelfContainedJSON() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: animation()) as? [String: Any])
        root["fonts"] = ["list": [["fName": "Unused", "fFamily": "Unused", "fStyle": "Regular",
                                   "fPath": "https://example.invalid/unused.woff", "fOrigin": "p"]]]
        let url = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: JSONSerialization.data(withJSONObject: root), runtime: .v461, plan: request(.json).plan)) { _ in }
        defer { ExportFileStore.remove(url) }
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fonts = try XCTUnwrap((output["fonts"] as? [String: Any])?["list"] as? [[String: Any]])
        XCTAssertNil(fonts[0]["fPath"], "A portable file should not request an unused external font")
    }

    func testOutlinedTextExportsDespiteExternalFontMetadataButMissingGlyphFails() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Stage4Fixture.animation(blur: true, text: "A")) as? [String: Any])
        root["fonts"] = ["list": [["fName": "ArialMT", "fFamily": "Arial", "fStyle": "Regular",
                                   "ascent": 75, "fPath": "outlined.woff", "fOrigin": "p"]]]
        let path: [String: Any] = ["c": true, "v": [[0, 0], [80, 0], [80, -100], [0, -100]],
            "i": [[0, 0], [0, 0], [0, 0], [0, 0]], "o": [[0, 0], [0, 0], [0, 0], [0, 0]]]
        root["chars"] = [["ch": "A", "size": 14, "style": "Regular", "w": 80, "fFamily": "Arial",
            "data": ["shapes": [["ty": "gr", "it": [["ty": "sh", "ks": ["a": 0, "k": path]]]]]]]]
        let base = request(.json)
        let url = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: JSONSerialization.data(withJSONObject: root), runtime: .v461, plan: base.plan)) { _ in }
        defer { ExportFileStore.remove(url) }
        let plan = AnimationExportPlan(format: .gif, size: CGSize(width: 100, height: 100),
            framesPerSecond: 10, duration: 0.1, transparent: true,
            backgroundColor: RGBAColor(red: 0, green: 0, blue: 0), gifQuality: 1)
        let gif = try await AnimationExporter().export(request: AnimationExportRequest(
            animationData: Data(contentsOf: url), runtime: .v461, plan: plan)) { _ in }
        defer { ExportFileStore.remove(gif) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let glyphPixels = bytes(image)
        XCTAssertGreaterThan(stride(from: 3, to: glyphPixels.count, by: 4).filter { glyphPixels[$0] > 0 }.count, 20)
        root["chars"] = []
        do {
            let unexpected = try await AnimationExporter().export(request: AnimationExportRequest(
                animationData: JSONSerialization.data(withJSONObject: root), runtime: .v461, plan: base.plan)) { _ in }
            ExportFileStore.remove(unexpected); XCTFail("A used external font without glyph coverage must still fail")
        } catch AnimationExportError.missingResource { }
    }

    func request(_ format: AnimationExportFormat, transparent: Bool = false) -> AnimationExportRequest {
        AnimationExportRequest(animationData: try! animation(), runtime: .v461,
            plan: AnimationExportPlan(format: format, size: CGSize(width: 128, height: 64),
                framesPerSecond: 30, duration: 1.01, transparent: transparent,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 1), gifQuality: 1))
    }

    func animation() throws -> Data {
        var ks = transform(position: [16, 32, 0])
        ks["p"] = ["a": 1, "k": [
            ["t": 60, "s": [16, 32, 0], "e": [112, 32, 0],
             "o": ["x": 0, "y": 0], "i": ["x": 1, "y": 1]],
            ["t": 161, "s": [112, 32, 0]]]]
        var cyanKS = transform(position: [16, 16, 0])
        cyanKS["p"] = ["a": 1, "k": [
            ["t": 60, "s": [16, 16, 0], "e": [112, 16, 0],
             "o": ["x": 0, "y": 0], "i": ["x": 1, "y": 1]],
            ["t": 161, "s": [112, 16, 0]]]]
        return try JSONSerialization.data(withJSONObject: ["v": "5.7.0", "fr": 100,
            "ip": 60, "op": 161, "w": 128, "h": 64, "assets": [],
            "layers": [["ddd": 0, "ind": 1, "ty": 4, "sr": 1, "ks": ks,
                "shapes": [["ty": "rc", "d": 1, "p": ["a": 0, "k": [0, 0]],
                            "s": ["a": 0, "k": [16, 16]], "r": ["a": 0, "k": 3]],
                           ["ty": "fl", "c": ["a": 0, "k": [1, 0, 0, 1]],
                            "o": ["a": 0, "k": 100], "r": 1]], "ip": 60, "op": 161, "st": 0],
                ["ddd": 0, "ind": 2, "ty": 4, "sr": 1, "ks": cyanKS,
                 "shapes": [["ty": "rc", "d": 1, "p": ["a": 0, "k": [0, 0]],
                             "s": ["a": 0, "k": [8, 8]], "r": ["a": 0, "k": 0]],
                            ["ty": "fl", "c": ["a": 0, "k": [0, 1, 1, 1]],
                             "o": ["a": 0, "k": 100], "r": 1]], "ip": 60, "op": 161, "st": 0]]])
    }

    func transform(position: [Int]) -> [String: Any] {
        ["o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0],
         "p": ["a": 0, "k": position], "a": ["a": 0, "k": [0, 0, 0]],
         "s": ["a": 0, "k": [100, 100, 100]]]
    }

    func decodeVideo(_ url: URL) async throws -> [(time: Double, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var frames: [(Double, CGImage)] = []
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            let image = try XCTUnwrap(CIContext().createCGImage(CIImage(cvPixelBuffer: buffer),
                from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))))
            frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, image))
        }
        XCTAssertEqual(reader.status, .completed)
        return frames
    }

    func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = bytes(image); let i = (y * image.width + x) * 4
        return Array(data[i..<i+4])
    }

    func redCenter(_ image: CGImage) throws -> Double {
        let data = bytes(image); var count = 0.0; var sum = 0.0
        for y in 0..<image.height { for x in 0..<image.width {
            let i = (y * image.width + x) * 4
            if data[i] > 180 && data[i+1] < 80 && data[i+2] < 80 && data[i+3] > 180 {
                sum += Double(x) + 0.5; count += 1
            }
        }}
        XCTAssertGreaterThan(count, 100)
        return sum / max(count, 1)
    }
}

private final class ExportTestCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    func set(_ completion: @escaping @Sendable () -> Void) {
        lock.lock(); self.completion = completion; lock.unlock()
    }
    func call() {
        lock.lock(); let action = completion; lock.unlock(); action?()
    }
}

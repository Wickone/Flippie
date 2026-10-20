import XCTest
import UIKit
import SwiftUI
import ImageIO
@testable import Flippie

@MainActor
final class ProjectPersistenceTests: XCTestCase {
    func testReopenedProjectPreservesEditsAndAssets() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try imageFixture(in: directory.appendingPathComponent("Input"))
        let location = directory.appendingPathComponent("Last.flippie")
        let original: Data
        do {
            let document = AnimationDocument()
            try document.load(data: input, sourceURL: directory.appendingPathComponent("Input/Example.json"))
            original = try XCTUnwrap(document.originalData)
            try document.apply(AnimationEdits(colorReplacements: [
                RGBAColor(red: 1, green: 0, blue: 0): RGBAColor(red: 0, green: 1, blue: 0)],
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 1), playbackSpeed: 1.5))
            document.selectRuntime(.v350)
            document.updateLoopMode(.autoReverse)
            try await ProjectStore().save(document.projectSnapshot(), at: location)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Input"))
        let project = try await ProjectStore().load(from: location)
        let reopened = AnimationDocument()
        try reopened.load(project: project)
        XCTAssertEqual(reopened.originalData, original, "Original bytes must not be baked together with edits")
        XCTAssertEqual(reopened.edits.playbackSpeed, 1.5)
        XCTAssertEqual(reopened.edits.colorReplacements[RGBAColor(red: 1, green: 0, blue: 0)], RGBAColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(reopened.edits.backgroundColor, RGBAColor(red: 0, green: 0, blue: 1))
        XCTAssertEqual(reopened.selectedRuntime, .v350)
        XCTAssertEqual(reopened.playbackLoopMode, .autoReverse)
        XCTAssertEqual(reopened.displayName, "Example")
        XCTAssertFalse(reopened.hasUnsavedChanges)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reopened.renderedData)) as? [String: Any])
        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        XCTAssertTrue(layers.contains { ($0["sc"] as? String)?.lowercased() == "#0000ff" })
        let rendered = try AnimationFrameRenderer(animationData: XCTUnwrap(reopened.renderedData), runtime: reopened.selectedRuntime,
            size: CGSize(width: 64, height: 64), transparent: false,
            backgroundColor: RGBAColor(red: 0, green: 0, blue: 1), assetBaseURL: reopened.assetBaseURL)
        defer { rendered.close() }
        let image = try await rendered.render(progress: 0, frameIndex: 0)
        XCTAssertGreaterThan(pixel(image, 32, 32)[0], 240, "The external red image must survive loss of the import folder")
        XCTAssertGreaterThan(pixel(image, 0, 0)[2], 240)
    }

    func testRestoredProjectExportsAutonomousJSONAndGIF() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let data = try imageFixture(in: directory.appendingPathComponent("Input"))
        let document = AnimationDocument()
        try document.load(data: data, sourceURL: directory.appendingPathComponent("Input/Test.json"))
        try document.apply(AnimationEdits(playbackSpeed: 2))
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(document.projectSnapshot(), at: location)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Input"))
        // New store and document emulate a process/app update with no retained importer object.
        let restored = AnimationDocument()
        try restored.load(project: await ProjectStore().load(from: location))
        for format in [AnimationExportFormat.json, .gif] {
            let plan = AnimationExportPlan(format: format, size: CGSize(width: 64, height: 64),
                framesPerSecond: 10, duration: 0.1, transparent: true,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0), gifQuality: 1)
            let url = try await AnimationExporter().export(request: AnimationExportRequest(
                animationData: XCTUnwrap(restored.renderedData), runtime: restored.selectedRuntime,
                plan: plan, assetBaseURL: restored.assetBaseURL)) { _ in }
            defer { ExportFileStore.remove(url) }
            if format == .json {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                XCTAssertTrue((((root["assets"] as? [[String: Any]])?.first?["p"]) as? String)?.hasPrefix("data:") == true)
            } else {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                XCTAssertGreaterThan(pixel(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), 32, 32)[3], 240)
            }
        }
    }

    func testFailedSaveLeavesPreviousValidProjectUntouched() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let store = ProjectStore()
        let old = try project()
        try await store.save(old, at: location)
        let before = try Data(contentsOf: location.appendingPathComponent("project.json"))
        var bad = try project()
        bad.assetBaseURL = directory.appendingPathComponent("DoesNotExist")
        do { try await store.save(bad, at: location); XCTFail("Missing input directory must not be treated as saved") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: location.appendingPathComponent("project.json")), before)
        let loaded = try await ProjectStore().load(from: location)
        XCTAssertEqual(loaded.id, old.id)
    }

    func testCorruptAndUnknownSchemaAreReportedWithoutMutation() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(project(), at: location)
        let manifest = location.appendingPathComponent("project.json")
        let valid = try Data(contentsOf: manifest)
        for data in [Data("broken".utf8), Data(#"{"schemaVersion":999}"#.utf8)] {
            try data.write(to: manifest, options: .atomic)
            do { _ = try await ProjectStore().load(from: location); XCTFail("Invalid project must not silently load") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: manifest), data)
        }
        try valid.write(to: manifest, options: .atomic)
        _ = try await ProjectStore().load(from: location)
    }

    func testLoaderRejectsEscapingPathsAndSymlinks() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(project(), at: location)
        let manifest = location.appendingPathComponent("project.json")
        let valid = try Data(contentsOf: manifest)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        root["originalPath"] = "../outside.json"
        try JSONSerialization.data(withJSONObject: root).write(to: manifest, options: .atomic)
        do { _ = try await ProjectStore().load(from: location); XCTFail("Traversal must be rejected") }
        catch { }
        try valid.write(to: manifest, options: .atomic)
        let loaded = try await ProjectStore().load(from: location)
        let originalURL = try XCTUnwrap(loaded.originalURL)
        let outside = directory.appendingPathComponent("outside.json")
        try loaded.originalData.write(to: outside)
        try FileManager.default.removeItem(at: originalURL)
        try FileManager.default.createSymbolicLink(at: originalURL, withDestinationURL: outside)
        do { _ = try await ProjectStore().load(from: location); XCTFail("Symlinks must not escape project ownership") }
        catch { }
    }

    func testUndoRedoAndFailedApplyDoNotPolluteHistory() async throws {
        let document = AnimationDocument(); try document.load(data: empty())
        try document.apply(AnimationEdits(playbackSpeed: 1.5))
        try document.apply(AnimationEdits(backgroundColor: RGBAColor(red: 0, green: 0, blue: 1), playbackSpeed: 2))
        XCTAssertTrue(try document.undo())
        XCTAssertEqual(document.edits, AnimationEdits(playbackSpeed: 1.5))
        XCTAssertTrue(try document.redo())
        XCTAssertEqual(document.edits.playbackSpeed, 2)
        let application = AnimationEditApplication()
        do {
            _ = try await application.apply(document: document, draft: { AnimationEdits(playbackSpeed: 3) }, setPlaybackSpeed: { _ in }) {
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("Failed prepare/save must not commit the draft")
        } catch { }
        XCTAssertEqual(document.edits.playbackSpeed, 2)
        XCTAssertTrue(try document.undo())
        XCTAssertEqual(document.edits, AnimationEdits(playbackSpeed: 1.5))
        try document.apply(AnimationEdits(playbackSpeed: 0.5))
        XCTAssertFalse(document.canRedo, "A new edit must truncate the redo branch")
    }

    func testDraftIsNotPersistedUntilApplied() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let document = AnimationDocument(); try document.load(data: empty())
        try document.apply(AnimationEdits(playbackSpeed: 1.5))
        let draft = AnimationEdits(backgroundColor: RGBAColor(red: 1, green: 0, blue: 0), playbackSpeed: 3)
        XCTAssertNotEqual(draft, document.edits)
        try await ProjectStore().save(document.projectSnapshot(), at: location)
        let restored = try await ProjectStore().load(from: location)
        XCTAssertEqual(restored.edits, AnimationEdits(playbackSpeed: 1.5))
    }

    func testInvalidEditsCannotReplaceSavedProject() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let good = try project(); try await ProjectStore().save(good, at: location)
        for speed in [0.0, Double.nan, Double.infinity, -1.0] {
            var invalid = good; invalid.edits.playbackSpeed = speed
            do { try await ProjectStore().save(invalid, at: location); XCTFail("Invalid playback must not be committed") }
            catch { }
        }
        let loaded = try await ProjectStore().load(from: location)
        XCTAssertEqual(loaded.edits.playbackSpeed, 1)
    }

    func testCancelledSaveKeepsLastProject() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let old = try project(); try await ProjectStore().save(old, at: location)
        let replacement = try project()
        let task = Task { try await ProjectStore().save(replacement, at: location) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled save must not report success") }
        catch is CancellationError { }
        let loaded = try await ProjectStore().load(from: location)
        XCTAssertEqual(loaded.id, old.id)
    }

    func testAutosaveQueueKeepsNewestRevisionAndRestoresPlaybackSession() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let persistence = ProjectPersistenceCoordinator(url: location)
        let document = AnimationDocument(); try document.load(data: empty())
        document.updatePlaybackSpeed(1.5)
        let first = try persistence.enqueue(document)
        document.updatePlaybackSpeed(2)
        document.updateLoopMode(.autoReverse)
        document.selectRuntime(.v400)
        let latest = try persistence.enqueue(document)
        try await first.value; try await latest.value
        XCTAssertFalse(document.hasUnsavedChanges)
        let restored = AnimationDocument(); let session = PlaybackSession()
        defer { session.close() }
        let loaded = try await ProjectPersistenceCoordinator(url: location).restore(document: restored, session: session)
        XCTAssertTrue(loaded)
        XCTAssertEqual(restored.edits.playbackSpeed, 2)
        XCTAssertEqual(session.speed, 2)
        XCTAssertEqual(session.loopMode, .autoReverse)
        XCTAssertEqual(session.player.runtime, .v400)
        XCTAssertTrue(session.hasAnimation)
        XCTAssertFalse(session.isPlaying, "Restoring must not unexpectedly auto-play")
    }

    func testLateSaveCannotReplaceNewDocumentLocation() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let persistence = ProjectPersistenceCoordinator(url: location)
        let document = AnimationDocument(); try document.load(data: empty())
        let old = try persistence.enqueue(document)
        try document.load(data: empty(), sourceURL: directory.appendingPathComponent("New.json"))
        let currentID = document.projectID
        try await old.value
        XCTAssertEqual(document.projectID, currentID)
        XCTAssertEqual(document.displayName, "New")
        XCTAssertTrue(document.hasUnsavedChanges)
    }

    func testRestoreDoesNotReplaceAlreadyOpenDocument() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(project(), at: location)
        let open = AnimationDocument(); try open.load(data: empty(), sourceURL: directory.appendingPathComponent("Keep.json"))
        let session = PlaybackSession(); defer { session.close() }
        let result = try await ProjectPersistenceCoordinator(url: location).restore(document: open, session: session)
        XCTAssertFalse(result)
        XCTAssertEqual(open.displayName, "Keep")
    }

    func testOnlyReferencedResourcesAreCopiedFromBundleLikeFolder() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Input")
        let data = try imageFixture(in: input)
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try Data("Not an animation resource".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: input.appendingPathComponent("AppExecutable"), withDestinationURL: unrelated)
        let doc = AnimationDocument(); try doc.load(data: data, sourceURL: input.appendingPathComponent("Sample.json"))
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(doc.projectSnapshot(), at: location)
        let loaded = try await ProjectStore().load(from: location)
        XCTAssertEqual(loaded.resourcePaths, ["images/sprite.png"])
    }

    func testFailedOldApplyDoesNotRollbackNewDocument() async throws {
        let doc = AnimationDocument(); try doc.load(data: empty())
        do {
            _ = try await AnimationEditApplication().apply(document: doc,
                draft: { AnimationEdits(playbackSpeed: 2) }, setPlaybackSpeed: { _ in }) {
                    try doc.load(data: self.empty(), sourceURL: URL(fileURLWithPath: "/tmp/New.json"))
                    try doc.apply(AnimationEdits(playbackSpeed: 0.5))
                    throw CocoaError(.fileReadCorruptFile)
                }
            XCTFail("Expected failure")
        } catch { }
        XCTAssertEqual(doc.displayName, "New")
        XCTAssertEqual(doc.edits.playbackSpeed, 0.5)
    }

    func testBackgroundSnapshotCannotSaveUncommittedApply() async throws {
        let doc = AnimationDocument(); try doc.load(data: empty())
        var leakedDraft: FlippieProject?
        do {
            _ = try await AnimationEditApplication().apply(document: doc,
                draft: { AnimationEdits(playbackSpeed: 2) }, setPlaybackSpeed: { _ in }) {
                    leakedDraft = try? doc.projectSnapshot()
                    throw CocoaError(.fileWriteNoPermission)
                }
        } catch { }
        XCTAssertNil(leakedDraft, "A scene-background save must not capture a provisional Edit draft")
        XCTAssertEqual(doc.edits.playbackSpeed, 1)
    }

    func testWritePermissionFailurePreservesPriorManifest() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let good = try project(); try await ProjectStore().save(good, at: location)
        let manifest = location.appendingPathComponent("project.json")
        let prior = try Data(contentsOf: manifest)
        var changed = good; changed.revision += 1; changed.edits.playbackSpeed = 2
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: location.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.path) }
        do { try await ProjectStore().save(changed, at: location); XCTFail("Read-only directory must not report a saved revision") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: manifest), prior)
        let restored = try await ProjectStore().load(from: location)
        XCTAssertEqual(restored.edits.playbackSpeed, 1)
    }

    func testContentViewStartsAtLandingWithoutOpeningOrChangingSavedProject() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(project(), at: location)
        let manifest = location.appendingPathComponent("project.json")
        let savedBytes = try Data(contentsOf: manifest)
        let doc = AnimationDocument(); let session = PlaybackSession()
        let controller = UIHostingController(rootView: ContentView(document: doc, session: session,
            persistence: ProjectPersistenceCoordinator(url: location)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller; window.isHidden = false
        defer { session.close(); window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(session.hasAnimation, "Startup must not automatically open the saved project")
        XCTAssertFalse(doc.isLoaded)
        XCTAssertEqual(try Data(contentsOf: manifest), savedBytes, "Showing the landing screen must preserve the saved project")
        _ = try await ProjectStore().load(from: location)
    }

    func testDamagedProjectCanBeQuarantinedBeforeSavingNewImport() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(project(), at: location)
        let damaged = Data("damaged project".utf8)
        try damaged.write(to: location.appendingPathComponent("project.json"), options: .atomic)
        let backup = try await ProjectStore().quarantineDamagedProject(at: location)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("project.json")), damaged)
        let new = try project(); try await ProjectStore().save(new, at: location)
        let restored = try await ProjectStore().load(from: location)
        XCTAssertEqual(restored.id, new.id)
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: location.appendingPathComponent("project.json"), options: .atomic)
        do { _ = try await ProjectStore().quarantineDamagedProject(at: location); XCTFail("Future formats must never be automatically replaced") }
        catch ProjectStoreError.unsupportedSchema(999) { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
    }

    func testExcessiveStagedDirectoryEntriesCannotReplacePriorProject() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let old = try project(); try await ProjectStore().save(old, at: location)
        let input = directory.appendingPathComponent("Input")
        let data = try imageFixture(in: input)
        let png = try Data(contentsOf: input.appendingPathComponent("images/sprite.png"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var assets: [[String: Any]] = []
        for index in 0..<2049 {
            let folder = "d\(index)"
            try FileManager.default.createDirectory(at: input.appendingPathComponent(folder), withIntermediateDirectories: true)
            try png.write(to: input.appendingPathComponent(folder + "/sprite.png"))
            assets.append(["id": "image\(index)", "w": 16, "h": 16, "p": "sprite.png", "u": folder + "/", "e": 0])
        }
        root["assets"] = assets; root["layers"] = []
        let doc = AnimationDocument(); try doc.load(data: JSONSerialization.data(withJSONObject: root), sourceURL: input.appendingPathComponent("Many.json"))
        do { try await ProjectStore().save(doc.projectSnapshot(), at: location); XCTFail("Save must not commit a package the loader rejects") }
        catch ProjectStoreError.resourceLimit { }
        let reopened = try await ProjectStore().load(from: location)
        XCTAssertEqual(reopened.id, old.id)
    }

    func testPersistenceUsesSameDecodableImageFallbackAsPreview() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Input")
        let data = try imageFixture(in: input)
        try FileManager.default.moveItem(at: input.appendingPathComponent("images/sprite.png"), to: input.appendingPathComponent("sprite.png"))
        try Data("Not an image".utf8).write(to: input.appendingPathComponent("images/sprite.png"))
        XCTAssertNotNil(LottieAssetResolver.image(name: "sprite.png", directory: "images/", baseURL: input))
        let doc = AnimationDocument(); try doc.load(data: data, sourceURL: input.appendingPathComponent("Fallback.json"))
        let location = directory.appendingPathComponent("Last.flippie")
        try await ProjectStore().save(doc.projectSnapshot(), at: location)
        try FileManager.default.removeItem(at: input)
        let result = try await ProjectStore().load(from: location)
        let base = try XCTUnwrap(result.assetBaseURL)
        let image = LottieAssetResolver.image(name: "sprite.png", directory: "images/", baseURL: base)
        XCTAssertNotNil(image, "Packing must not replace the visible fallback with a corrupt shadow file")
    }

    func testInterruptedSaveStagingIsCleanedWithoutRemovingCurrentSource() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Last.flippie")
        let snapshot = try project(); try await ProjectStore().save(snapshot, at: location)
        let abandoned = location.appendingPathComponent("Sources/.staging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("partial copy".utf8).write(to: abandoned.appendingPathComponent("partial"))
        try await ProjectStore().save(snapshot, at: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        let result = try await ProjectStore().load(from: location)
        XCTAssertEqual(result.originalData, snapshot.originalData)
    }

    func testSavingAnotherWindowCannotDeleteOpenProjectsImages() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Input")
        let data = try imageFixture(in: input)
        let location = directory.appendingPathComponent("Last.flippie")
        let doc = AnimationDocument(); try doc.load(data: data, sourceURL: input.appendingPathComponent("A.json"))
        try await ProjectStore().save(doc.projectSnapshot(), at: location)
        let openInOtherWindow = try await ProjectStore().load(from: location)
        let source = try XCTUnwrap(openInOtherWindow.originalURL).deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: source.path)
        try await ProjectStore().save(project(), at: location)
        try await ProjectStore().save(project(), at: location)
        let base = try XCTUnwrap(openInOtherWindow.assetBaseURL)
        XCTAssertNotNil(LottieAssetResolver.image(name: "sprite.png", directory: "images/", baseURL: base),
                        "Cleaning prior versions must not remove resources held by a live document or queued snapshot")
    }

    func project() throws -> FlippieProject {
        let document = AnimationDocument(); try document.load(data: empty())
        return try document.projectSnapshot()
    }

    func empty() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": "5.7.0", "fr": 30, "ip": 0, "op": 30,
            "w": 64, "h": 64, "layers": [], "assets": []])
    }

    func imageFixture(in folder: URL) throws -> Data {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).pngData { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try png.write(to: folder.appendingPathComponent("images/sprite.png"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: empty()) as? [String: Any])
        root["assets"] = [["id": "image", "w": 16, "h": 16, "p": "sprite.png", "u": "images/", "e": 0]]
        root["layers"] = [["ty": 2, "ind": 1, "ddd": 0, "refId": "image", "sr": 1, "ip": 0, "op": 30, "st": 0,
            "ks": ["o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0],
                   "p": ["a": 0, "k": [24, 24, 0]], "a": ["a": 0, "k": [0, 0, 0]], "s": ["a": 0, "k": [100, 100, 100]]]]]
        return try JSONSerialization.data(withJSONObject: root)
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("project-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let c = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4; return Array(pixels[i..<i+4])
    }
}

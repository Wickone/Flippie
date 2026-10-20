import XCTest
import UIKit
import zlib
@testable import Flippie

@MainActor
final class LottieImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOversizedNumericFieldsReturnRecoverableError() throws {
        for field in ["w", "h", "fr", "ip", "op"] {
            XCTAssertThrowsError(try LottieImportService.validate(animation([field: 1e20])), field)
        }
        XCTAssertThrowsError(try LottieImportService.validate(animation(["w": 16384, "h": 16384])))
        XCTAssertThrowsError(try LottieImportService.validate(animation(["layers": [["ty": 1e20]]])))
    }

    func testDuplicateAssetIDsReturnRecoverableError() throws {
        XCTAssertThrowsError(try LottieImportService.validate(animation([
            "assets": [["id": "same", "layers": []], ["id": "same", "layers": []]],
        ])))
    }

    func testBooleanRequiredNumbersAndOversizedAssetDimensionsAreRejected() throws {
        for field in ["w", "h", "fr", "ip", "op"] {
            XCTAssertThrowsError(try LottieImportService.validate(animation([field: true])), field)
        }
        XCTAssertThrowsError(try LottieImportService.validate(animation([
            "assets": [["id": "big", "p": "pixel.png", "w": 100000, "h": 100000]],
        ])))
    }

    func testInvalidDocumentLoadPreservesCurrentDocument() throws {
        let document = AnimationDocument()
        let valid = try animation(["nm": "Keep me"])
        try document.load(data: valid)
        XCTAssertThrowsError(try document.load(data: animation(["w": 1e20])))
        XCTAssertEqual(document.originalData, valid)
        XCTAssertEqual(document.metadata?.width, 100)
    }

    func testImportNamedManifestPreservesManifestBytes() async throws {
        let manifest = Data(#"{"version":"1.0","animations":[{"id":"main"}]}"#.utf8)
        let imported = try await importArchive("manifest", [
            ("manifest.json", manifest), ("animations/main.json", try animation()),
        ])
        defer { remove(imported) }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(imported.manifestURL)), manifest)
    }

    func testImportDoesNotOverwriteSameBasenameRootJSON() async throws {
        let preserved = Data(#"{"keep":"original metadata"}"#.utf8)
        let imported = try await importArchive("sample", [
            ("sample.json", preserved), ("animations/main.json", try animation()),
        ])
        defer { remove(imported) }
        XCTAssertEqual(try Data(contentsOf: imported.packageURL.appendingPathComponent("sample.json")), preserved)
    }

    func testExactAssetPathWinsOverRootBasename() async throws {
        let rootImage = try png(.red)
        let nestedImage = try png(.blue)
        let imported = try await importArchive("images", [
            ("animations/main.json", try animation(["assets": [imageAsset("image", "icons/")]])),
            ("pixel.png", rootImage), ("icons/pixel.png", nestedImage),
        ])
        defer { remove(imported) }
        let resolved = try XCTUnwrap(imported.report.imageAssets.first?.resolvedURL)
        XCTAssertEqual(try Data(contentsOf: resolved), nestedImage)
        XCTAssertEqual(imported.report.resolvedExternalImageCount, 1)
    }

    func testCorruptImageIsNotReportedAsFound() async throws {
        let imported = try await importArchive("corrupt-image", [
            ("animations/main.json", try animation(["assets": [imageAsset("image", "icons/")]])),
            ("icons/pixel.png", Data("not an image".utf8)),
        ])
        defer { remove(imported) }
        XCTAssertEqual(imported.report.resolvedExternalImageCount, 0)
        XCTAssertEqual(imported.report.missingExternalImageCount, 1)
    }

    func testInflateRejectsForgedUncompressedSizeDuringStreaming() async throws {
        let url = directory.appendingPathComponent("bomb.lottie")
        try zip([("animations/main.json", Data(repeating: 32, count: 131072))],
                deflated: true, declaredSize: 8).write(to: url)
        do {
            let imported = try await LottieImportService.importAnimation(from: url)
            remove(imported)
            XCTFail("Forged size must be rejected while producing output")
        } catch LottieImportError.archiveEntryTooLarge("animations/main.json") {
            // Distinct from the old, late size-mismatch error.
        } catch {
            XCTFail("Expected streaming size guard, got \(error)")
        }
    }

    func testCRCFailureRejectsArchive() async throws {
        let url = directory.appendingPathComponent("bad-crc.lottie")
        try zip([("animations/main.json", try animation())], corruptCRC: true).write(to: url)
        do {
            let imported = try await LottieImportService.importAnimation(from: url)
            remove(imported)
            XCTFail("Archive with damaged CRC must be rejected")
        } catch LottieImportError.invalidArchive { }
    }

    func testCancelledImportDoesNotCreatePackage() async throws {
        let url = directory.appendingPathComponent("cancelled.json")
        try animation().write(to: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LottieImportService.importAnimation(from: url)
        }
        do {
            let imported = try await task.value
            remove(imported)
            XCTFail("Cancelled import must stop")
        } catch is CancellationError { }
    }

    func testLongUnicodeSourceNameUsesValidOwnedFileNames() async throws {
        let name = String(repeating: "а", count: 110)
        let url = directory.appendingPathComponent(name + ".json")
        try animation().write(to: url)
        let imported = try await LottieImportService.importAnimation(from: url)
        defer { remove(imported) }
        XCTAssertEqual(imported.report.sourceFileName, name + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.url.path))
        XCTAssertLessThanOrEqual(imported.packageURL.lastPathComponent.utf8.count, 255)
    }

    func testRepairFailureDoesNotModifyOriginalPackage() async throws {
        let url = directory.appendingPathComponent("repair.json")
        try animation(["assets": [imageAsset("a", "images/"), imageAsset("b", "blocked/")]])
            .write(to: url)
        let imported = try await LottieImportService.importAnimation(from: url)
        defer { remove(imported) }
        let blocker = imported.packageURL.appendingPathComponent("blocked")
        try Data("keep".utf8).write(to: blocker)
        let search = directory.appendingPathComponent("repair-source")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try png(.red).write(to: search.appendingPathComponent("pixel.png"))
        do {
            _ = try await LottieImportService.repairMissingAssets(in: imported.report, from: search)
            XCTFail("Destination is blocked by a file")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.packageURL.appendingPathComponent("images/pixel.png").path))
        XCTAssertEqual(try Data(contentsOf: blocker), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: imported.url), imported.data)
    }

    func testRepairCannotOverwriteManifestOrPlaybackJSON() async throws {
        for target in ["manifest.json", "protected-playback.json"] {
            let original = try animation(["assets": [["id": "image", "u": "", "p": target]]])
            let manifest = Data(#"{"version":"2","animations":[{"id":"main"}]}"#.utf8)
            let imported = try await importArchive("protected-playback", [
                ("manifest.json", manifest), ("a/main.json", original),
            ])
            defer { remove(imported) }
            let search = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
            try png(.red).write(to: search.appendingPathComponent(target))
            do {
                _ = try await LottieImportService.repairMissingAssets(in: imported.report, from: search)
                XCTFail("Repair may not overwrite \(target)")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: imported.url), imported.data)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(imported.manifestURL)), manifest)
            XCTAssertEqual(try Data(contentsOf: imported.packageURL.appendingPathComponent("a/main.json")), original)
        }
    }

    func testJSONAssetFallbackCannotOverwriteOwnedAnimation() async throws {
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try png(.red).write(to: images.appendingPathComponent("sample.json"))
        let url = directory.appendingPathComponent("sample.json")
        try animation(["assets": [["id": "image", "u": "", "p": "sample.json"]]]).write(to: url)
        let imports = FileManager.documentsDirectory().appendingPathComponent("Flippie Imports")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
        do {
            let imported = try await LottieImportService.importAnimation(from: url)
            remove(imported)
            XCTFail("Asset bytes must not overwrite the playback JSON")
        } catch { }
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []), before)
    }

    func testRepairHonorsRemainingBudgetAndRollsBack() async throws {
        let data = try animation(["assets": [imageAsset("first", "one/"), imageAsset("second", "two/")]])
        let url = directory.appendingPathComponent("budget.json")
        try data.write(to: url)
        let imported = try await LottieImportService.importAnimation(from: url)
        defer { remove(imported) }
        let search = directory.appendingPathComponent("budget-images")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        let image = try png(.blue)
        try image.write(to: search.appendingPathComponent("pixel.png"))
        do {
            _ = try await LottieImportService.repairMissingAssets(
                in: imported.report, from: search, packageSizeLimit: data.count + image.count
            )
            XCTFail("Only one image fits the remaining package budget")
        } catch LottieImportError.fileTooLarge { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.packageURL.appendingPathComponent("one/pixel.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.packageURL.appendingPathComponent("two/pixel.png").path))
        XCTAssertEqual(try Data(contentsOf: imported.url), data)
    }

    func testMissingAnimationRelativeAssetCanBeRepaired() async throws {
        let original = try animation(["assets": [imageAsset("image", "../i/")]])
        let imported = try await importArchive("missing-relative", [("a/main.json", original)])
        defer { remove(imported) }
        XCTAssertEqual(imported.report.imageAssets.first?.candidatePaths.first, "i/pixel.png")
        let search = directory.appendingPathComponent("relative-images")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try png(.blue).write(to: search.appendingPathComponent("pixel.png"))
        let repaired = try await LottieImportService.repairMissingAssets(in: imported.report, from: search)
        XCTAssertEqual(repaired.resolvedExternalImageCount, 1)
        XCTAssertEqual(try Data(contentsOf: imported.packageURL.appendingPathComponent("a/main.json")), original)
    }

    func testRepairCanShareOneCopiedResourceBetweenMultipleAssets() async throws {
        let url = directory.appendingPathComponent("shared.json")
        try animation(["assets": [imageAsset("one", "images/"), imageAsset("two", "images/")]]).write(to: url)
        let imported = try await LottieImportService.importAnimation(from: url)
        defer { remove(imported) }
        let search = directory.appendingPathComponent("shared-images")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try png(.blue).write(to: search.appendingPathComponent("pixel.png"))
        let repaired = try await LottieImportService.repairMissingAssets(in: imported.report, from: search)
        XCTAssertEqual(repaired.resolvedExternalImageCount, 2)
        XCTAssertEqual(Set(repaired.imageAssets.compactMap(\.resolvedURL)).count, 1)
        XCTAssertEqual(repaired.packageFileCount, 2)
    }

    func testRecursiveRepairChecksCancellationOnNonmatchingEntries() async throws {
        let base = directory!
        let task = Task {
            var yielded = false
            let entries = AnySequence<URL> {
                AnyIterator<URL> {
                    guard !yielded else { return nil }
                    yielded = true
                    withUnsafeCurrentTask { $0?.cancel() }
                    return base.appendingPathComponent("not-the-requested-image.txt")
                }
            }
            return try LottieImportService.findRepairCandidate(in: entries, names: ["pixel.png"], directory: base)
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must be checked before filtering an entry")
        } catch is CancellationError { }
    }

    func testMultipleAnimationsAreListedInManifestOrderForBothVersions() async throws {
        for (version, folder) in [("1.0", "animations"), ("2", "a")] {
            let manifest = Data("{\"version\":\"\(version)\",\"animations\":[{\"id\":\"second\"},{\"id\":\"first\"}]}".utf8)
            let imported = try await importArchive("multi-\(version)", [
                ("manifest.json", manifest),
                ("\(folder)/first.json", try animation(["nm": "First"])),
                ("\(folder)/second.json", try animation(["nm": "Second"])),
            ])
            defer { remove(imported) }
            XCTAssertEqual(imported.report.animations.map(\.animationID), ["second", "first"])
            XCTAssertEqual(imported.report.selectedAnimationPath, "\(folder)/second.json")
        }
    }

    func testAnimationSelectionPreservesCompletePackageAndOriginalJSON() async throws {
        let first = try animation(["nm": "First"])
        let second = try animation(["nm": "Second", "w": 200])
        let manifest = Data(#"{"version":"2","initial":{"animation":"first"},"animations":[{"id":"first"},{"id":"second"}],"themes":[{"id":"light"}],"stateMachines":[{"id":"interactive"}]}"#.utf8)
        let extras = [("t/light.json", Data("{}".utf8)), ("s/interactive.json", Data("{}".utf8)),
                      ("f/brand.ttf", Data("font bytes".utf8))]
        let imported = try await importArchive("selection", [
            ("manifest.json", manifest), ("a/first.json", first), ("a/second.json", second),
        ] + extras)
        defer { remove(imported) }
        let selected = try await LottieImportService.selectAnimation(path: "a/second.json", in: imported)
        XCTAssertEqual(selected.data, second)
        XCTAssertEqual(selected.packageURL, imported.packageURL)
        XCTAssertEqual(selected.report.selectedAnimationPath, "a/second.json")
        XCTAssertEqual(selected.report.animations.count, 2)
        XCTAssertGreaterThanOrEqual(selected.report.warnings.count, 3)
        XCTAssertEqual(try Data(contentsOf: imported.packageURL.appendingPathComponent("a/first.json")), first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(selected.manifestURL)), manifest)
        for (path, data) in extras {
            XCTAssertEqual(try Data(contentsOf: selected.packageURL.appendingPathComponent(path)), data)
        }
    }

    func testSelectionRejectsPathsOutsideAnimationCatalogWithoutChanges() async throws {
        let imported = try await importArchive("invalid-selection", [("a/main.json", try animation())])
        defer { remove(imported) }
        do {
            _ = try await LottieImportService.selectAnimation(path: "../outside.json", in: imported)
            XCTFail("Only known animation paths may be selected")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: imported.url), imported.data)
    }

    func testMalformedManifestFallsBackWithWarning() async throws {
        let imported = try await importArchive("bad-manifest", [
            ("manifest.json", Data("{broken".utf8)), ("a/main.json", try animation()),
        ])
        defer { remove(imported) }
        XCTAssertEqual(imported.report.animations.count, 1)
        XCTAssertFalse(imported.report.warnings.isEmpty)
    }

    func testJSONPackageSurvivesRemovalOfSourceAndUsesSharedResolver() async throws {
        let images = directory.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let image = try png(.blue)
        try image.write(to: images.appendingPathComponent("pixel.png"))
        let url = directory.appendingPathComponent("portable.json")
        try animation(["assets": [imageAsset("image", "icons/")]]).write(to: url)
        let imported = try await LottieImportService.importAnimation(from: url)
        defer { remove(imported) }
        try FileManager.default.removeItem(at: directory)
        let resolution = LottieAssetResolver.resolve(name: "pixel.png", directory: "icons/", baseURL: imported.packageURL)
        XCTAssertEqual(resolution.url, imported.report.imageAssets.first?.resolvedURL)
        XCTAssertNotNil(resolution.image)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(resolution.url)), image)
        let player = VersionedLottiePlayerView()
        for runtime in LottieRuntimeVersion.allCases {
            XCTAssertNoThrow(try player.load(data: imported.data, runtime: runtime, baseURL: imported.packageURL))
        }
    }

    func testUnsafeDuplicateAndOversizedZipEntriesLeaveNoPackage() async throws {
        let cases: [[(String, Data)]] = [
            [("../escape.json", try animation())],
            [("/absolute.json", try animation())],
            [("a/main.json", try animation()), ("a/main.json", try animation())],
            [("a/MAIN.json", try animation()), ("a/main.json", try animation())],
        ]
        let imports = FileManager.documentsDirectory().appendingPathComponent("Flippie Imports")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
        for (index, entries) in cases.enumerated() {
            do {
                let imported = try await importArchive("unsafe-\(index)", entries)
                remove(imported)
                XCTFail("Unsafe/ambiguous archive must be rejected")
            } catch { }
        }
        let oversized = directory.appendingPathComponent("oversized.lottie")
        try zip([("a/main.json", try animation())], declaredSize: 301 * 1024 * 1024).write(to: oversized)
        do {
            let imported = try await LottieImportService.importAnimation(from: oversized)
            remove(imported)
            XCTFail("Declared expanded size must be rejected before allocation")
        } catch { }
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []), before)
    }

    func testSymlinkCannotEscapeAssetFolder() throws {
        let owned = directory.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside.png")
        try png(.red).write(to: outside)
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("pixel.png"), withDestinationURL: outside)
        XCTAssertNil(LottieAssetResolver.resolve(name: "pixel.png", directory: "", baseURL: owned).image)
    }

    func testNestedAnimationAndV2ImagePathsBecomePortableWithoutChangingPayload() async throws {
        for (directoryPath, imagePath) in [("../i/", "i/pixel.png"), ("icons/", "a/icons/pixel.png"), ("", "i/pixel.png")] {
            let original = try animation(["assets": [imageAsset("image", directoryPath)]])
            let imported = try await importArchive("relative-\(UUID().uuidString)", [
                ("a/main.json", original), (imagePath, try png(.blue)),
            ])
            defer { remove(imported) }
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: imported.data) as? [String: Any])
            let asset = try XCTUnwrap((root["assets"] as? [[String: Any]])?.first)
            let resolution = LottieAssetResolver.resolve(
                name: asset["p"] as? String ?? "", directory: asset["u"] as? String ?? "", baseURL: imported.packageURL
            )
            XCTAssertNotNil(resolution.image)
            XCTAssertEqual(resolution.url, imported.report.imageAssets.first?.resolvedURL)
            XCTAssertEqual(try Data(contentsOf: imported.packageURL.appendingPathComponent("a/main.json")), original)
        }
    }

    func testCancellationDuringExtractionRollsBackStagingPackage() async throws {
        let imports = FileManager.documentsDirectory().appendingPathComponent("Flippie Imports")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
        let url = directory.appendingPathComponent("cancel-during-extraction.lottie")
        var entries = (0..<2000).map { ("resources/\($0).bin", Data(repeating: 42, count: 1024)) }
        entries.append(("a/main.json", try animation()))
        try zip(entries).write(to: url)
        let task = Task { try await LottieImportService.importAnimation(from: url) }
        var startedExtraction = false
        for _ in 0..<5000 {
            let current = Set((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? [])
            if current.subtracting(before).contains(where: { $0.hasSuffix(".staging") }) {
                startedExtraction = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do {
            let imported = try await task.value
            remove(imported)
            XCTFail("In-flight extraction must observe cancellation")
        } catch is CancellationError { }
        XCTAssertTrue(startedExtraction, "The test must cancel after the worker has started extracting")
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []), before)
    }

    private func animation(_ overrides: [String: Any] = [:]) throws -> Data {
        var json: [String: Any] = ["v": "5.7.0", "fr": 30, "ip": 0, "op": 60,
                                   "w": 100, "h": 100, "layers": []]
        json.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func imageAsset(_ id: String, _ path: String) -> [String: Any] {
        ["id": id, "u": path, "p": "pixel.png", "e": 0, "w": 2, "h": 2]
    }

    private func png(_ color: UIColor) throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData())
    }

    private func importArchive(_ name: String, _ entries: [(String, Data)]) async throws -> ImportedLottieFile {
        let url = directory.appendingPathComponent("\(name).lottie")
        try zip(entries).write(to: url)
        return try await LottieImportService.importAnimation(from: url)
    }

    private func remove(_ imported: ImportedLottieFile) {
        try? FileManager.default.removeItem(at: imported.packageURL)
    }

    private func zip(_ entries: [(String, Data)], deflated: Bool = false,
                     declaredSize: UInt32? = nil, corruptCRC: Bool = false) throws -> Data {
        var output = Data()
        var central = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        for (path, bytes) in entries {
            let name = Data(path.utf8)
            let compressed = deflated ? try deflate(bytes) : bytes
            let checksum = bytes.withUnsafeBytes {
                UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
            } ^ (corruptCRC ? 1 : 0)
            let offset = UInt32(output.count)
            append(UInt32(0x04034b50), to: &output)
            for value: UInt16 in [20, 0, deflated ? 8 : 0, 0, 0] { append(value, to: &output) }
            append(checksum, to: &output)
            append(UInt32(compressed.count), to: &output)
            append(declaredSize ?? UInt32(bytes.count), to: &output)
            append(UInt16(name.count), to: &output)
            append(UInt16(0), to: &output)
            output.append(name)
            output.append(compressed)
            append(UInt32(0x02014b50), to: &central)
            for value: UInt16 in [20, 20, 0, deflated ? 8 : 0, 0, 0] { append(value, to: &central) }
            append(checksum, to: &central)
            append(UInt32(compressed.count), to: &central)
            append(declaredSize ?? UInt32(bytes.count), to: &central)
            append(UInt16(name.count), to: &central)
            for _ in 0..<4 { append(UInt16(0), to: &central) }
            append(UInt32(0), to: &central)
            append(offset, to: &central)
            central.append(name)
        }
        let offset = UInt32(output.count)
        output.append(central)
        append(UInt32(0x06054b50), to: &output)
        append(UInt16(0), to: &output)
        append(UInt16(0), to: &output)
        append(UInt16(entries.count), to: &output)
        append(UInt16(entries.count), to: &output)
        append(UInt32(central.count), to: &output)
        append(offset, to: &output)
        append(UInt16(0), to: &output)
        return output
    }

    private func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                                    Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var output = Data(count: input.count + 1024)
        let status = input.withUnsafeBytes { raw in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return output.prefix(Int(stream.total_out))
    }
}

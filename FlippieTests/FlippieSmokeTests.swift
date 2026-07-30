import XCTest
import AVFoundation
import UIKit
import zlib
@testable import Flippie

@MainActor
final class FlippieSmokeTests: XCTestCase {
    func testContentViewCanBeCreated() {
        XCTAssertNotNil(ContentView())
    }

    func testDocumentsDirectoryIsAFileURL() {
        XCTAssertTrue(FileManager.documentsDirectory().isFileURL)
    }

    func testRuntimeComparisonMatrixIsStable() {
        XCTAssertEqual(
            LottieRuntimeVersion.allCases.map(\.rawValue),
            ["3.0.0", "3.5.0", "4.0.0", "4.6.1"]
        )
        XCTAssertEqual(LottieRuntimeVersion.embedded, .v461)
        XCTAssertEqual(LottieRuntimeVersion.v300.shortTitle, "3.0")
        XCTAssertEqual(LottieRuntimeVersion.v461.shortTitle, "4.6")
    }

    func testEveryRuntimeLoadsInsideOnePlayer() throws {
        let player = VersionedLottiePlayerView()
        let data = try JSONSerialization.data(withJSONObject: [
            "v": "5.7.0",
            "fr": 30,
            "ip": 0,
            "op": 60,
            "w": 100,
            "h": 100,
            "layers": [],
        ])

        for runtime in LottieRuntimeVersion.allCases {
            let range = try player.load(data: data, runtime: runtime)
            XCTAssertEqual(player.runtime, runtime)
            XCTAssertEqual(range.start, 0)
            XCTAssertEqual(range.end, 60)
        }
    }

    func testFailedRuntimeLoadKeepsCurrentPlayer() throws {
        let player = VersionedLottiePlayerView()
        let validData = try makeEmptyAnimationData()
        _ = try player.load(data: validData, runtime: .v461)
        player.currentProgress = 0.4

        XCTAssertThrowsError(
            try player.load(data: Data("{}".utf8), runtime: .v300)
        )
        XCTAssertEqual(player.runtime, .v461)
        XCTAssertEqual(player.currentProgress, 0.4, accuracy: 0.01)
    }

    func testImportValidationRejectsNonLottieJSON() {
        let data = Data(#"{"name":"not a lottie"}"#.utf8)

        XCTAssertThrowsError(try LottieImportService.validate(data)) { error in
            guard case LottieImportError.missingField("layers") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testImportValidationAcceptsValidLottieJSON() throws {
        XCTAssertNoThrow(
            try LottieImportService.validate(makeEmptyAnimationData())
        )
    }

    func testDotLottieImportSelectsManifestAnimation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let animationData = try makeEmptyAnimationData()
        let manifestData = Data(
            #"{"version":"1.0","activeAnimationId":"main","animations":[{"id":"main"}]}"#.utf8
        )
        let archiveURL = temporaryDirectory.appendingPathComponent("sample.lottie")
        try makeStoredZipArchive(entries: [
            ("manifest.json", manifestData),
            ("animations/main.json", animationData),
        ]).write(to: archiveURL, options: .atomic)

        let imported = try await LottieImportService.importAnimation(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: imported.packageURL) }

        XCTAssertEqual(imported.data, animationData)
        XCTAssertEqual(imported.url.lastPathComponent, "sample.json")
        XCTAssertEqual(imported.url.deletingLastPathComponent(), imported.packageURL)
        XCTAssertNotNil(imported.manifestURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.url.path))
        XCTAssertEqual(imported.report.kind, .dotLottie)
        XCTAssertEqual(imported.report.selectedAnimationPath, "animations/main.json")
        XCTAssertEqual(imported.report.imageAssets.count, 0)
    }

    func testDotLottieImportReadsV2InitialAnimation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let animationData = try makeEmptyAnimationData()
        let manifestData = Data(
            #"{"version":"2.0","initial":{"animation":"hero"},"animations":[{"id":"hero"}]}"#.utf8
        )
        let archiveURL = temporaryDirectory.appendingPathComponent("v2.lottie")
        try makeStoredZipArchive(entries: [
            ("manifest.json", manifestData),
            ("a/hero.json", animationData),
        ]).write(to: archiveURL, options: .atomic)

        let imported = try await LottieImportService.importAnimation(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: imported.packageURL) }

        XCTAssertEqual(imported.data, animationData)
        XCTAssertEqual(imported.url.lastPathComponent, "v2.json")
        XCTAssertEqual(imported.report.selectedAnimationPath, "a/hero.json")
    }

    func testDotLottieImportSupportsDeflatedArchives() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let animationData = try makeEmptyAnimationData()
        let archiveURL = temporaryDirectory.appendingPathComponent("deflated.lottie")
        try makeDeflatedZipArchive(entries: [
            ("animations/main.json", animationData),
        ]).write(to: archiveURL, options: .atomic)

        let imported = try await LottieImportService.importAnimation(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: imported.packageURL) }

        XCTAssertEqual(imported.data, animationData)
        XCTAssertEqual(imported.url.lastPathComponent, "deflated.json")
    }

    func testJSONImportCopiesSiblingExternalAssetsIntoPackage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imagesDirectory = temporaryDirectory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: imagesDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        try imageData.write(to: imagesDirectory.appendingPathComponent("photo.png"))

        let jsonData = try JSONSerialization.data(withJSONObject: [
            "v": "5.7.0",
            "fr": 30,
            "ip": 0,
            "op": 30,
            "w": 100,
            "h": 100,
            "layers": [],
            "assets": [[
                "id": "image_0",
                "u": "images/",
                "p": "photo.png",
                "e": 0,
            ]],
        ])
        let jsonURL = temporaryDirectory.appendingPathComponent("external-image.json")
        try jsonData.write(to: jsonURL)

        let imported = try await LottieImportService.importAnimation(from: jsonURL)
        defer { try? FileManager.default.removeItem(at: imported.packageURL) }

        let copiedImageURL = imported.packageURL
            .appendingPathComponent("images")
            .appendingPathComponent("photo.png")
        XCTAssertEqual(try Data(contentsOf: copiedImageURL), imageData)
        XCTAssertEqual(imported.report.kind, .json)
        XCTAssertEqual(imported.report.resolvedExternalImageCount, 1)
        XCTAssertEqual(imported.report.missingExternalImageCount, 0)
        XCTAssertEqual(imported.report.imageAssets.first?.copiedFromURL?.lastPathComponent, "photo.png")
    }

    func testImportReportFlagsMissingExternalAssets() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let jsonData = try JSONSerialization.data(withJSONObject: [
            "v": "5.7.0",
            "fr": 30,
            "ip": 0,
            "op": 30,
            "w": 100,
            "h": 100,
            "layers": [],
            "assets": [[
                "id": "image_missing",
                "u": "images/",
                "p": "missing.png",
                "e": 0,
            ]],
        ])
        let jsonURL = temporaryDirectory.appendingPathComponent("missing-image.json")
        try jsonData.write(to: jsonURL)

        let imported = try await LottieImportService.importAnimation(from: jsonURL)
        defer { try? FileManager.default.removeItem(at: imported.packageURL) }

        XCTAssertEqual(imported.report.resolvedExternalImageCount, 0)
        XCTAssertEqual(imported.report.missingExternalImageCount, 1)
        XCTAssertTrue(imported.report.hasAssetProblems)
        XCTAssertEqual(imported.report.imageAssets.first?.candidatePaths.first, "missing.png")
    }

    func testRepairMissingAssetsCopiesFoundImagesIntoPackage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assetSearchDirectory = temporaryDirectory.appendingPathComponent("asset-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetSearchDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        try imageData.write(to: assetSearchDirectory.appendingPathComponent("missing.png"))

        let jsonData = try JSONSerialization.data(withJSONObject: [
            "v": "5.7.0",
            "fr": 30,
            "ip": 0,
            "op": 30,
            "w": 100,
            "h": 100,
            "layers": [],
            "assets": [[
                "id": "image_missing",
                "u": "images/",
                "p": "missing.png",
                "e": 0,
            ]],
        ])
        let jsonURL = temporaryDirectory.appendingPathComponent("repairable.json")
        try jsonData.write(to: jsonURL)

        let imported = try await LottieImportService.importAnimation(from: jsonURL)
        defer { try? FileManager.default.removeItem(at: imported.packageURL) }
        XCTAssertEqual(imported.report.missingExternalImageCount, 1)

        let repairedReport = try await LottieImportService.repairMissingAssets(
            in: imported.report,
            from: assetSearchDirectory
        )

        XCTAssertEqual(repairedReport.missingExternalImageCount, 0)
        XCTAssertEqual(repairedReport.resolvedExternalImageCount, 1)
        XCTAssertEqual(repairedReport.imageAssets.first?.copiedFromURL?.lastPathComponent, "missing.png")
        XCTAssertEqual(
            try Data(contentsOf: imported.packageURL.appendingPathComponent("images/missing.png")),
            imageData
        )
    }

    func testExternalImageAssetsUseNativeVersionedPlayers() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imagesDirectory = temporaryDirectory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: imagesDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try makeTestPNGData().write(to: imagesDirectory.appendingPathComponent("pixel.png"))
        let data = try makeExternalImageAnimationData()

        XCTAssertFalse(AnimationDocument.requiresWebRenderer(data))

        let player = VersionedLottiePlayerView()
        for runtime in LottieRuntimeVersion.allCases {
            _ = try player.load(data: data, runtime: runtime, baseURL: temporaryDirectory)
            XCTAssertFalse(player.usesWebRenderer)
            XCTAssertEqual(player.runtime, runtime)
        }
    }

    func testGaussianBlurIsReportedWithoutDroppingLayers() throws {
        let layers: [[String: Any]] = (1...11).map { index in
            var layer: [String: Any] = [
                "ind": index,
                "ty": 4,
                "nm": index == 4 ? "Group 2" : "Layer \(index)",
                "ip": 0,
                "op": 120,
                "st": 0,
                "ks": [:],
                "shapes": [],
            ]
            if index == 4 {
                layer["ef"] = [[
                    "ty": 29,
                    "nm": "Gaussian Blur",
                    "ef": [[
                        "ty": 0,
                        "nm": "Blurriness",
                        "v": ["a": 0, "k": 42],
                    ]],
                ]]
            }
            return layer
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "v": "5.5.2",
            "fr": 60,
            "ip": 0,
            "op": 120,
            "w": 512,
            "h": 512,
            "layers": layers,
            "assets": [],
        ])

        let document = AnimationDocument()
        try document.load(data: data)

        XCTAssertEqual(document.metadata?.layerCount, 11)
        XCTAssertTrue(document.hasRenderingLimitations)
        XCTAssertEqual(document.renderingDiagnostics.count, 1)
        XCTAssertTrue(
            document.renderingDiagnostics[0].message.contains("Group 2")
        )
        XCTAssertTrue(
            document.renderingDiagnostics[0].message.contains("Gaussian Blur")
        )
    }

    func testStarUsesWebRendererAndProducesBlurSnapshot() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "test_star",
                withExtension: "json"
            )
        )
        let data = try Data(contentsOf: url)
        let player = VersionedLottiePlayerView(
            frame: CGRect(x: 0, y: 0, width: 256, height: 256)
        )
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 256, height: 256)
        )
        let viewController = UIViewController()
        viewController.view.frame = window.bounds
        viewController.view.addSubview(player)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let range = try player.load(data: data, runtime: .v461)
        player.frame = window.bounds
        window.layoutIfNeeded()
        player.layoutIfNeeded()

        XCTAssertTrue(player.usesWebRenderer)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 120)

        for progress in [0.0, 0.25, 0.5, 0.75, 0.99] {
            try await player.prepareFrame(progress: progress)
            let optionalImage = try await player.webSnapshotCGImage(
                size: CGSize(width: 256, height: 256)
            )
            let image = try XCTUnwrap(optionalImage)
            XCTAssertGreaterThanOrEqual(image.width, 256)
            XCTAssertGreaterThanOrEqual(image.height, 256)
            XCTAssertTrue(containsVisibleColorVariation(image))

            let attachment = XCTAttachment(
                image: UIImage(cgImage: image)
            )
            attachment.name = "test-star-gaussian-blur-\(progress)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testStarExportsThroughGaussianBlurRenderer() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "test_star",
                withExtension: "json"
            )
        )
        let data = try Data(contentsOf: url)
        let request = AnimationExportRequest(
            animationData: data,
            runtime: .v461,
            plan: AnimationExportPlan(
                format: .gif,
                size: CGSize(width: 64, height: 64),
                framesPerSecond: 10,
                duration: 0.1,
                transparent: true,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0),
                gifQuality: 1
            )
        )

        let outputURL = try await AnimationExporter().export(
            request: request
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: outputURL).count, 0)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(outputURL as CFURL, nil)
        )
        let firstFrame = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        XCTAssertTrue(containsVisibleColorVariation(firstFrame))
    }

    func testBundledSamplesLoadInEveryRuntime() throws {
        let sampleNames = BundledAnimationsView { _ in }.bundledAnimations
        XCTAssertEqual(sampleNames.count, 6)

        for name in sampleNames {
            let exactURL = Bundle.main.url(forResource: name, withExtension: nil)
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ".json", with: "")
            let url = try XCTUnwrap(
                exactURL ?? Bundle.main.url(forResource: cleanName, withExtension: "json"),
                "Missing bundled sample \(name)"
            )
            let data = try Data(contentsOf: url)
            let document = AnimationDocument()
            try document.load(data: data, sourceURL: url)

            for runtime in LottieRuntimeVersion.allCases {
                let player = VersionedLottiePlayerView()
                XCTAssertNoThrow(
                    try player.load(data: data, runtime: runtime),
                    "\(url.lastPathComponent) failed in lottie-ios \(runtime.rawValue)"
                )
            }
        }
    }

    func testDocumentExtractsMetadataAndDiagnostics() throws {
        let document = AnimationDocument()
        try document.load(data: makeAnimationData(keyframed: true))

        XCTAssertEqual(document.metadata?.formatVersion, "5.12.1")
        XCTAssertEqual(document.metadata?.frameRate, 60)
        XCTAssertEqual(document.metadata?.frameCount, 120)
        XCTAssertEqual(document.metadata?.duration, 2)
        XCTAssertEqual(document.metadata?.width, 200)
        XCTAssertEqual(document.metadata?.height, 100)
        XCTAssertEqual(document.metadata?.layerCount, 1)
        XCTAssertTrue(document.diagnostics.contains { $0.id == "keyframed-colors" })
    }

    func testFeatureSummaryScansAdvancedLottieImportMap() throws {
        let data = try makeAdvancedFeatureAnimationData()
        let document = AnimationDocument()
        try document.load(data: data)

        let features = try XCTUnwrap(document.metadata?.features)
        XCTAssertEqual(features.totalLayerCount, 4)
        XCTAssertEqual(features.precompositionAssetCount, 1)
        XCTAssertEqual(features.imageAssetCount, 1)
        XCTAssertEqual(features.externalImageAssetCount, 1)
        XCTAssertEqual(features.maskCount, 1)
        XCTAssertEqual(features.matteCount, 1)
        XCTAssertEqual(features.effectCount, 1)
        XCTAssertEqual(features.gaussianBlurCount, 1)
        XCTAssertEqual(features.textLayerCount, 1)
        XCTAssertEqual(features.threeDLayerCount, 1)
        XCTAssertEqual(features.timeRemapCount, 1)
        XCTAssertEqual(features.gradientCount, 1)
        XCTAssertEqual(features.trimPathCount, 1)
        XCTAssertEqual(features.mergePathCount, 1)
        XCTAssertEqual(features.repeaterCount, 1)
        XCTAssertEqual(features.markerCount, 1)
        XCTAssertEqual(features.slotCount, 1)
        XCTAssertGreaterThanOrEqual(features.sidPropertyCount, 2)
        XCTAssertGreaterThanOrEqual(features.keyframedPropertyCount, 2)
        XCTAssertEqual(features.keyframedColorCount, 1)
        XCTAssertEqual(features.expressionCount, 1)

        XCTAssertTrue(document.diagnostics.contains { $0.id == "external-image-assets" })
        XCTAssertTrue(document.diagnostics.contains { $0.id == "precompositions" })
        XCTAssertTrue(document.diagnostics.contains { $0.id == "masks-mattes" })
        XCTAssertTrue(document.renderingDiagnostics.contains { $0.message.contains("Gaussian Blur") })
    }

    func testDocumentAppliesStaticColorReplacement() throws {
        let edits = AnimationEdits(colorReplacements: [
            RGBAColor(red: 1, green: 0, blue: 0): RGBAColor(red: 0, green: 1, blue: 0)
        ])

        let rendered = try AnimationDocument.renderedData(
            from: makeAnimationData(keyframed: false),
            edits: edits
        )

        XCTAssertEqual(try firstColorComponents(in: rendered), [0, 1, 0, 1])
    }

    func testDocumentAppliesKeyframedColorReplacement() throws {
        let edits = AnimationEdits(colorReplacements: [
            RGBAColor(red: 1, green: 0, blue: 0): RGBAColor(red: 0, green: 0, blue: 1)
        ])

        let rendered = try AnimationDocument.renderedData(
            from: makeAnimationData(keyframed: true),
            edits: edits
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rendered) as? [String: Any]
        )
        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        let shapes = try XCTUnwrap(layers.first?["shapes"] as? [[String: Any]])
        let color = try XCTUnwrap(shapes.first?["c"] as? [String: Any])
        let keyframes = try XCTUnwrap(color["k"] as? [[String: Any]])

        XCTAssertEqual(keyframes.first?["s"] as? [Double], [0, 0, 1, 1])
        XCTAssertEqual(keyframes.first?["e"] as? [Double], [0, 0, 1, 1])
    }

    func testDocumentAppliesColorReplacementInsidePrecompAsset() throws {
        let data = try makeAnimationWithPrecomp()
        let edits = AnimationEdits(colorReplacements: [
            RGBAColor(red: 0, green: 1, blue: 0): RGBAColor(red: 1, green: 0, blue: 1)
        ])

        let rendered = try AnimationDocument.renderedData(from: data, edits: edits)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rendered) as? [String: Any]
        )
        let assets = try XCTUnwrap(root["assets"] as? [[String: Any]])
        let layers = try XCTUnwrap(assets.first?["layers"] as? [[String: Any]])
        let shapes = try XCTUnwrap(layers.first?["shapes"] as? [[String: Any]])
        let color = try XCTUnwrap(shapes.first?["c"] as? [String: Any])

        XCTAssertEqual(color["k"] as? [Double], [1, 0, 1, 1])
    }

    func testColorDiscoveryIncludesKeyframesAndPrecomps() throws {
        let colors = try AnimationDocument.discoveredColors(
            in: makeAnimationWithPrecomp()
        )

        XCTAssertTrue(colors.contains(RGBAColor(red: 1, green: 0, blue: 0)))
        XCTAssertTrue(colors.contains(RGBAColor(red: 0, green: 0, blue: 1)))
        XCTAssertTrue(colors.contains(RGBAColor(red: 0, green: 1, blue: 0)))
    }

    func testDocumentKeepsAppliedEditorChanges() throws {
        let document = AnimationDocument()
        try document.load(data: makeAnimationData(keyframed: false))
        let edits = AnimationEdits(
            colorReplacements: [
                RGBAColor(red: 1, green: 0, blue: 0):
                    RGBAColor(red: 0, green: 1, blue: 0)
            ],
            backgroundColor: RGBAColor(red: 0.1, green: 0.2, blue: 0.3),
            playbackSpeed: 1.5
        )

        try document.apply(edits)

        XCTAssertEqual(document.edits, edits)
        XCTAssertNotNil(document.renderedData)
    }

    func testBackgroundBecomesARealLottieSolidLayer() throws {
        let background = RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.75)
        let rendered = try AnimationDocument.renderedData(
            from: makeEmptyAnimationData(),
            edits: AnimationEdits(backgroundColor: background)
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rendered) as? [String: Any]
        )
        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        let backgroundLayer = try XCTUnwrap(
            layers.first { $0["nm"] as? String == "__FlippieBackground" }
        )

        XCTAssertEqual(backgroundLayer["ty"] as? Int, 1)
        XCTAssertEqual(backgroundLayer["sc"] as? String, "#336699")
        XCTAssertEqual(backgroundLayer["sw"] as? Int, 200)
        XCTAssertEqual(backgroundLayer["sh"] as? Int, 100)
        let transform = try XCTUnwrap(backgroundLayer["ks"] as? [String: Any])
        let opacity = try XCTUnwrap(transform["o"] as? [String: Any])
        XCTAssertEqual(opacity["k"] as? Double, 75)

        let player = VersionedLottiePlayerView()
        for renderingMode in [LottieRenderingMode.coreAnimation, .mainThread] {
            XCTAssertNoThrow(try player.load(
                data: rendered,
                runtime: .v461,
                renderingMode: renderingMode
            ))
        }
    }

    func testExportPlanCalculatesFramesAndVideoSize() throws {
        let plan = AnimationExportPlan(
            format: .mp4,
            size: CGSize(width: 101, height: 99),
            framesPerSecond: 30,
            duration: 2,
            transparent: false,
            backgroundColor: RGBAColor(red: 1, green: 1, blue: 1),
            gifQuality: 0.9
        )

        try plan.validate()
        XCTAssertEqual(plan.frameCount, 60)
        XCTAssertEqual(plan.outputSize, CGSize(width: 102, height: 100))
    }

    func testExportPlanRejectsTransparentMP4() {
        let plan = AnimationExportPlan(
            format: .mp4,
            size: CGSize(width: 100, height: 100),
            framesPerSecond: 30,
            duration: 1,
            transparent: true,
            backgroundColor: RGBAColor(red: 1, green: 1, blue: 1),
            gifQuality: 0.9
        )

        XCTAssertThrowsError(try plan.validate()) { error in
            guard case AnimationExportError.transparencyUnsupported(.mp4) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGIFExporterWritesAFile() async throws {
        let request = AnimationExportRequest(
            animationData: try makeEmptyAnimationData(),
            runtime: .embedded,
            plan: AnimationExportPlan(
                format: .gif,
                size: CGSize(width: 16, height: 16),
                framesPerSecond: 10,
                duration: 0.1,
                transparent: true,
                backgroundColor: RGBAColor(red: 1, green: 1, blue: 1),
                gifQuality: 1
            ),
            preferredFileName: "Demo/Bad:Name"
        )

        let url = try await AnimationExporter().export(request: request) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Demo-Bad-Name-"))
        XCTAssertGreaterThan(
            try Data(contentsOf: url).count,
            0
        )
    }

    func testMP4ExporterWritesAFile() async throws {
        let request = AnimationExportRequest(
            animationData: try makeEmptyAnimationData(),
            runtime: .embedded,
            plan: AnimationExportPlan(
                format: .mp4,
                size: CGSize(width: 16, height: 16),
                framesPerSecond: 10,
                duration: 0.1,
                transparent: false,
                backgroundColor: RGBAColor(red: 1, green: 1, blue: 1),
                gifQuality: 1
            )
        )

        let url = try await AnimationExporter().export(request: request) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(
            try Data(contentsOf: url).count,
            0
        )

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(description),
            kCMVideoCodecType_H264
        )
    }

    func testTransparentMOVExporterUsesHEVCWithAlpha() async throws {
        let request = AnimationExportRequest(
            animationData: try makeEmptyAnimationData(),
            runtime: .embedded,
            plan: AnimationExportPlan(
                format: .mov,
                size: CGSize(width: 16, height: 16),
                framesPerSecond: 10,
                duration: 0.1,
                transparent: true,
                backgroundColor: RGBAColor(red: 1, green: 1, blue: 1),
                gifQuality: 1
            )
        )

        do {
            let url = try await AnimationExporter().export(request: request) { _ in }
            defer { try? FileManager.default.removeItem(at: url) }

            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first)

            XCTAssertEqual(url.pathExtension, "mov")
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(description),
                kCMVideoCodecType_HEVCWithAlpha
            )
        } catch AnimationExportError.alphaEncodingUnavailable {
            // Simulator configurations without an alpha-capable HEVC encoder
            // must fail explicitly instead of returning an opaque video.
        }
    }

    func testExportCancellationRemovesPartialFile() async throws {
        let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let filesBefore = try Set(
            FileManager.default.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("Flippie-") }
        )
        let request = AnimationExportRequest(
            animationData: try makeEmptyAnimationData(),
            runtime: .embedded,
            plan: AnimationExportPlan(
                format: .gif,
                size: CGSize(width: 128, height: 128),
                framesPerSecond: 60,
                duration: 10,
                transparent: true,
                backgroundColor: RGBAColor(red: 1, green: 1, blue: 1),
                gifQuality: 1
            )
        )

        let task = Task { @MainActor in
            try await AnimationExporter().export(request: request) { _ in }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Export should have been cancelled.")
        } catch is CancellationError {
            // Expected.
        }

        let filesAfter = try Set(
            FileManager.default.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("Flippie-") }
        )
        XCTAssertEqual(filesAfter, filesBefore)
    }

    private func makeAnimationData(keyframed: Bool) throws -> Data {
        let colorValue: Any = keyframed
            ? [["t": 0, "s": [1.0, 0.0, 0.0, 1.0], "e": [1.0, 0.0, 0.0, 1.0]]]
            : [1.0, 0.0, 0.0, 1.0]
        let json: [String: Any] = [
            "v": "5.12.1",
            "fr": 60,
            "ip": 0,
            "op": 120,
            "w": 200,
            "h": 100,
            "layers": [[
                "ty": 4,
                "shapes": [[
                    "ty": "fl",
                    "c": ["a": keyframed ? 1 : 0, "k": colorValue],
                    "o": ["a": 0, "k": 100],
                    "r": 1,
                ]]
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func makeEmptyAnimationData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": "5.7.0",
            "fr": 30,
            "ip": 0,
            "op": 60,
            "w": 200,
            "h": 100,
            "layers": [],
        ])
    }

    private func makeAnimationWithPrecomp() throws -> Data {
        let json: [String: Any] = [
            "v": "5.12.1",
            "fr": 30,
            "ip": 0,
            "op": 60,
            "w": 100,
            "h": 100,
            "layers": [[
                "ty": 4,
                "shapes": [[
                    "ty": "fl",
                    "c": [
                        "a": 1,
                        "k": [[
                            "t": 0,
                            "s": [1.0, 0.0, 0.0, 1.0],
                            "e": [0.0, 0.0, 1.0, 1.0],
                        ]],
                    ],
                ]],
            ]],
            "assets": [[
                "id": "precomp_1",
                "layers": [[
                    "ty": 4,
                    "shapes": [[
                        "ty": "st",
                        "c": ["a": 0, "k": [0.0, 1.0, 0.0, 1.0]],
                    ]],
                ]],
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func makeAdvancedFeatureAnimationData() throws -> Data {
        let json: [String: Any] = [
            "v": "5.12.1",
            "fr": 60,
            "ip": 0,
            "op": 120,
            "w": 512,
            "h": 512,
            "markers": [["cm": "intro", "tm": 0, "dr": 30]],
            "slots": [["sid": "primary-color"]],
            "layers": [
                [
                    "ind": 1,
                    "ty": 0,
                    "nm": "Nested precomp",
                    "refId": "precomp_1",
                    "ddd": 1,
                    "tt": 1,
                    "tm": ["a": 1, "k": [["t": 0, "s": [0], "e": [15]]]],
                    "masksProperties": [[
                        "mode": "a",
                        "pt": ["a": 0, "k": ["i": [], "o": [], "v": [], "c": true]],
                    ]],
                    "ks": [
                        "o": ["a": 1, "k": [["t": 0, "s": [100], "e": [70]]], "x": "value + time"],
                    ],
                    "ef": [[
                        "ty": 29,
                        "nm": "Gaussian Blur",
                        "ef": [[
                            "ty": 0,
                            "nm": "Blurriness",
                            "v": ["a": 0, "k": 20],
                        ]],
                    ]],
                ],
                [
                    "ind": 2,
                    "ty": 2,
                    "nm": "External image",
                    "refId": "image_1",
                ],
                [
                    "ind": 3,
                    "ty": 5,
                    "nm": "Title",
                ],
            ],
            "assets": [
                [
                    "id": "precomp_1",
                    "layers": [[
                        "ind": 4,
                        "ty": 4,
                        "nm": "Advanced vector",
                        "shapes": [[
                            "ty": "gr",
                            "it": [
                                [
                                    "ty": "fl",
                                    "c": [
                                        "sid": "primary-color",
                                        "a": 1,
                                        "k": [[
                                            "t": 0,
                                            "s": [1.0, 0.0, 0.0, 1.0],
                                            "e": [0.0, 0.0, 1.0, 1.0],
                                        ]],
                                    ],
                                ],
                                ["ty": "gf"],
                                ["ty": "tm"],
                                ["ty": "mm"],
                                ["ty": "rp"],
                            ],
                        ]],
                    ]],
                ],
                [
                    "id": "image_1",
                    "u": "images/",
                    "p": "photo.png",
                    "e": 0,
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func makeExternalImageAnimationData() throws -> Data {
        let json: [String: Any] = [
            "v": "5.7.0",
            "fr": 30,
            "ip": 0,
            "op": 30,
            "w": 100,
            "h": 100,
            "assets": [[
                "id": "image_0",
                "w": 2,
                "h": 2,
                "u": "images/",
                "p": "pixel.png",
                "e": 0,
            ]],
            "layers": [[
                "ddd": 0,
                "ind": 1,
                "ty": 2,
                "nm": "Pixel",
                "refId": "image_0",
                "ks": [
                    "o": ["a": 0, "k": 100],
                    "r": ["a": 0, "k": 0],
                    "p": ["a": 0, "k": [50, 50, 0]],
                    "a": ["a": 0, "k": [1, 1, 0]],
                    "s": ["a": 0, "k": [100, 100, 100]],
                ],
                "ip": 0,
                "op": 30,
                "st": 0,
                "bm": 0,
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func makeTestPNGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func firstColorComponents(in data: Data) throws -> [Double] {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        let shapes = try XCTUnwrap(layers.first?["shapes"] as? [[String: Any]])
        let color = try XCTUnwrap(shapes.first?["c"] as? [String: Any])
        return try XCTUnwrap(color["k"] as? [Double])
    }

    private func makeStoredZipArchive(entries: [(path: String, data: Data)]) throws -> Data {
        try makeZipArchive(entries: entries, compression: .stored)
    }

    private func makeDeflatedZipArchive(entries: [(path: String, data: Data)]) throws -> Data {
        try makeZipArchive(entries: entries, compression: .deflated)
    }

    private func makeZipArchive(
        entries: [(path: String, data: Data)],
        compression: TestZipCompression
    ) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            guard let nameData = entry.path.data(using: .utf8),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw LottieImportError.invalidArchive
            }

            let compressedData: Data
            let compressionMethod: UInt16
            switch compression {
            case .stored:
                compressedData = entry.data
                compressionMethod = 0
            case .deflated:
                compressedData = try rawDeflate(entry.data)
                compressionMethod = 8
            }

            let localHeaderOffset = UInt32(archive.count)
            appendUInt32LE(0x0403_4B50, to: &archive)
            appendUInt16LE(20, to: &archive)
            appendUInt16LE(0, to: &archive)
            appendUInt16LE(compressionMethod, to: &archive)
            appendUInt16LE(0, to: &archive)
            appendUInt16LE(0, to: &archive)
            appendUInt32LE(0, to: &archive)
            appendUInt32LE(UInt32(compressedData.count), to: &archive)
            appendUInt32LE(UInt32(entry.data.count), to: &archive)
            appendUInt16LE(UInt16(nameData.count), to: &archive)
            appendUInt16LE(0, to: &archive)
            archive.append(nameData)
            archive.append(compressedData)

            appendUInt32LE(0x0201_4B50, to: &centralDirectory)
            appendUInt16LE(20, to: &centralDirectory)
            appendUInt16LE(20, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(compressionMethod, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt32LE(0, to: &centralDirectory)
            appendUInt32LE(UInt32(compressedData.count), to: &centralDirectory)
            appendUInt32LE(UInt32(entry.data.count), to: &centralDirectory)
            appendUInt16LE(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt32LE(0, to: &centralDirectory)
            appendUInt32LE(localHeaderOffset, to: &centralDirectory)
            centralDirectory.append(nameData)
        }

        guard entries.count <= Int(UInt16.max),
              centralDirectory.count <= Int(UInt32.max),
              archive.count <= Int(UInt32.max) else {
            throw LottieImportError.invalidArchive
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        appendUInt32LE(0x0605_4B50, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt16LE(UInt16(entries.count), to: &archive)
        appendUInt16LE(UInt16(entries.count), to: &archive)
        appendUInt32LE(UInt32(centralDirectory.count), to: &archive)
        appendUInt32LE(centralDirectoryOffset, to: &archive)
        appendUInt16LE(0, to: &archive)

        return archive
    }

    private func rawDeflate(_ input: Data) throws -> Data {
        if input.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -15,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw LottieImportError.invalidArchive
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        var status: Int32 = Z_OK

        try input.withUnsafeBytes { rawBuffer in
            guard let inputBaseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw LottieImportError.invalidArchive
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress)
            stream.avail_in = uInt(input.count)

            repeat {
                let chunkSize = 16 * 1_024
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                var produced = 0
                chunk.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
            } while status == Z_OK
        }

        guard status == Z_STREAM_END else {
            throw LottieImportError.invalidArchive
        }
        return output
    }

    private enum TestZipCompression {
        case stored
        case deflated
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8((value >> 8) & 0x00FF))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x0000_00FF))
        data.append(UInt8((value >> 8) & 0x0000_00FF))
        data.append(UInt8((value >> 16) & 0x0000_00FF))
        data.append(UInt8((value >> 24) & 0x0000_00FF))
    }

    private func containsVisibleColorVariation(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        var colors = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let color = UInt32(pixels[index]) << 24
                | UInt32(pixels[index + 1]) << 16
                | UInt32(pixels[index + 2]) << 8
                | UInt32(pixels[index + 3])
            colors.insert(color)
            if colors.count > 32 {
                return true
            }
        }
        return false
    }
}

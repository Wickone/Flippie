import Foundation
import CoreFoundation
import zlib

struct ImportedLottieFile: Identifiable, Sendable {
    let url: URL
    let data: Data
    let packageURL: URL
    let manifestURL: URL?
    let report: LottieImportReport
    var id: String { packageURL.path }
}

struct LottieImportReport: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case json = "JSON"
        case dotLottie = ".lottie"
    }

    let id = UUID()
    let sourceFileName: String
    let kind: Kind
    let packageURL: URL
    let animationURL: URL
    let manifestURL: URL?
    let selectedAnimationPath: String?
    let packageFileCount: Int
    let packageSizeBytes: Int
    let imageAssets: [LottieImportAssetReport]
    var animations: [LottiePackageAnimation] = []
    var warnings: [String] = []

    var embeddedImageCount: Int {
        imageAssets.filter { $0.status == .embedded }.count
    }

    var resolvedExternalImageCount: Int {
        imageAssets.filter { $0.status == .resolved }.count
    }

    var missingExternalImageCount: Int {
        imageAssets.filter { $0.status == .missing }.count
    }

    var unsupportedRemoteImageCount: Int {
        imageAssets.filter { $0.status == .remoteUnsupported }.count
    }

    var hasAssetProblems: Bool {
        missingExternalImageCount > 0 || unsupportedRemoteImageCount > 0
    }
}

struct LottieImportAssetReport: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case embedded
        case resolved
        case missing
        case remoteUnsupported
    }

    let id: String
    let assetID: String?
    let path: String
    let status: Status
    let resolvedURL: URL?
    let candidatePaths: [String]
    let copiedFromURL: URL?
}

enum LottieImportError: LocalizedError {
    case accessDenied
    case emptyFile
    case fileTooLarge
    case invalidJSON
    case invalidRoot
    case missingField(String)
    case invalidDimensions
    case invalidFrameRate
    case invalidFrameRange
    case invalidArchive
    case missingDotLottieAnimation
    case unsupportedArchiveCompression(String)
    case unsafeArchivePath(String)
    case archiveEntryTooLarge(String)
    case noRepairableAssetsFound
    case duplicateAssetID(String)
    case numericLimitExceeded
    case resourceCollision(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Flippie could not access the selected file."
        case .emptyFile:
            "The selected animation file is empty."
        case .fileTooLarge:
            "The selected animation file is too large."
        case .invalidJSON:
            "The selected file contains invalid JSON."
        case .invalidRoot:
            "A Lottie file must contain a JSON object at its root."
        case .missingField(let field):
            "The selected file is missing the required Lottie field “\(field)”."
        case .invalidDimensions:
            "Canvas dimensions must be whole pixels from 1 to 16,384, with at most 16,777,216 pixels."
        case .invalidFrameRate:
            "The Lottie frame rate must be greater than zero and no more than 1,000 fps."
        case .invalidFrameRange:
            "The end frame must follow the start frame, with a duration no longer than 24 hours."
        case .invalidArchive:
            "The selected .lottie archive is invalid or damaged."
        case .missingDotLottieAnimation:
            "The .lottie archive does not contain a readable animation JSON."
        case .unsupportedArchiveCompression(let path):
            "The .lottie archive uses unsupported compression for “\(path)”."
        case .unsafeArchivePath(let path):
            "The .lottie archive contains an unsafe file path: “\(path)”."
        case .archiveEntryTooLarge(let path):
            "The .lottie archive entry “\(path)” is too large."
        case .noRepairableAssetsFound:
            "Flippie could not find any missing image assets in the selected folder."
        case .duplicateAssetID(let id):
            "The animation contains a duplicate asset ID: “\(id)”."
        case .numericLimitExceeded:
            "The animation exceeds Flippie’s safe numeric or complexity limits."
        case .resourceCollision(let path):
            "The image asset “\(path)” would overwrite an existing package file. No files were changed."
        }
    }
}

enum LottieImportService {
    private static let maximumJSONSize = 50 * 1_024 * 1_024
    private static let maximumArchiveSize = 250 * 1_024 * 1_024
    private static let maximumExpandedArchiveSize = 300 * 1_024 * 1_024
    private static let importsDirectoryName = "Flippie Imports"

    static func selectAnimation(path: String, in imported: ImportedLottieFile) async throws -> ImportedLottieFile {
        try await cancellableWork {
            guard imported.report.animations.contains(where: { $0.path == path }),
                  let sourceURL = LottieAssetResolver.fileURL(path, in: imported.packageURL) else {
                throw LottieImportError.missingDotLottieAnimation
            }
            let data = try portableAnimationData(
                readBounded(sourceURL, limit: maximumJSONSize), sourceURL: sourceURL, packageURL: imported.packageURL
            )
            try validate(data)
            let stagedURL = imported.packageURL.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).staging")
            defer { try? FileManager.default.removeItem(at: stagedURL) }
            try FileManager.default.copyItem(at: imported.packageURL, to: stagedURL)
            try data.write(to: stagedURL.appendingPathComponent(imported.url.lastPathComponent), options: .atomic)
            try checkPackageBudget(stagedURL)
            try Task.checkCancellation()
            _ = try FileManager.default.replaceItemAt(imported.packageURL, withItemAt: stagedURL)
            let report = makeReport(
                sourceURL: URL(fileURLWithPath: imported.report.sourceFileName), kind: imported.report.kind,
                data: data, packageURL: imported.packageURL, animationURL: imported.url,
                manifestURL: imported.manifestURL, selectedAnimationPath: path, copiedAssets: [:],
                animations: imported.report.animations, warnings: imported.report.warnings
            )
            return ImportedLottieFile(url: imported.url, data: data, packageURL: imported.packageURL,
                                      manifestURL: imported.manifestURL, report: report)
        }
    }

    static func importAnimation(from sourceURL: URL) async throws -> ImportedLottieFile {
        try Task.checkCancellation()
        if sourceURL.pathExtension.lowercased() == "lottie" {
            return try await importDotLottie(from: sourceURL)
        }
        return try await importJSON(from: sourceURL)
    }

    static func repairMissingAssets(
        in report: LottieImportReport,
        from searchDirectory: URL
    ) async throws -> LottieImportReport {
        try await repairMissingAssets(in: report, from: searchDirectory, packageSizeLimit: maximumExpandedArchiveSize)
    }

    static func repairMissingAssets(
        in report: LottieImportReport,
        from searchDirectory: URL,
        packageSizeLimit: Int
    ) async throws -> LottieImportReport {
        try await cancellableWork {
            try withSecurityScopedAccess(to: searchDirectory) {
                guard packageSizeLimit > 0, packageSizeLimit <= maximumExpandedArchiveSize else {
                    throw LottieImportError.fileTooLarge
                }
                var remainingBudget = try remainingPackageBudget(at: report.packageURL, limit: packageSizeLimit)
                let stagedURL = report.packageURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).staging")
                defer { try? FileManager.default.removeItem(at: stagedURL) }
                try FileManager.default.copyItem(at: report.packageURL, to: stagedURL)
                let missingAssets = report.imageAssets.filter { $0.status == .missing }
                var copiedAssets: [String: URL] = [:]

                for asset in missingAssets {
                    try Task.checkCancellation()
                    guard let sourceURL = try findRepairAsset(for: asset, in: searchDirectory),
                          let destinationPath = preferredRepairDestinationPath(for: asset) else {
                        continue
                    }

                    guard let destinationURL = LottieAssetResolver.fileURL(destinationPath, in: stagedURL) else {
                        throw LottieImportError.unsafeArchivePath(destinationPath)
                    }
                    if copiedAssets[destinationPath] != nil { continue }
                    try copyOwnedAsset(from: sourceURL, to: destinationURL, path: destinationPath, remainingBudget: &remainingBudget)
                    copiedAssets[destinationPath] = sourceURL
                }

                guard !copiedAssets.isEmpty else {
                    throw LottieImportError.noRepairableAssetsFound
                }

                guard let playbackPath = relativePath(from: report.animationURL, in: report.packageURL),
                      let stagedPlaybackURL = LottieAssetResolver.fileURL(playbackPath, in: stagedURL) else {
                    throw LottieImportError.invalidJSON
                }
                let data = try readBounded(stagedPlaybackURL, limit: maximumJSONSize)
                try validate(data)
                _ = try remainingPackageBudget(at: stagedURL, limit: packageSizeLimit)
                try Task.checkCancellation()
                _ = try FileManager.default.replaceItemAt(report.packageURL, withItemAt: stagedURL)
                return makeReport(
                    sourceURL: URL(fileURLWithPath: report.sourceFileName),
                    kind: report.kind,
                    data: data,
                    packageURL: report.packageURL,
                    animationURL: report.animationURL,
                    manifestURL: report.manifestURL,
                    selectedAnimationPath: report.selectedAnimationPath,
                    copiedAssets: copiedAssets,
                    animations: report.animations, warnings: report.warnings
                )
            }
        }
    }

    static func importJSON(from sourceURL: URL) async throws -> ImportedLottieFile {
        try await cancellableWork {
            try withSecurityScopedAccess(to: sourceURL) {
                let data = try readBounded(sourceURL, limit: maximumJSONSize)
                try validate(data)

                let finalURL = try uniquePackageDirectoryURL(for: sourceURL)
                let packageURL = finalURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).staging")
                defer { try? FileManager.default.removeItem(at: packageURL) }
                try FileManager.default.createDirectory(
                    at: packageURL,
                    withIntermediateDirectories: true
                )

                let destinationURL = packageURL.appendingPathComponent(
                    "\(safeBaseName(for: sourceURL)).json"
                )
                try data.write(to: destinationURL, options: .atomic)
                let copiedAssets = try copyExternalAssets(
                    referencedBy: data,
                    originalJSONURL: sourceURL,
                    packageURL: packageURL
                )
                try checkPackageBudget(packageURL)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: packageURL, to: finalURL)
                let finalAnimationURL = finalURL.appendingPathComponent(destinationURL.lastPathComponent)
                let report = makeReport(
                    sourceURL: sourceURL,
                    kind: .json,
                    data: data,
                    packageURL: finalURL,
                    animationURL: finalAnimationURL,
                    manifestURL: nil,
                    selectedAnimationPath: nil,
                    copiedAssets: copiedAssets
                )

                return ImportedLottieFile(
                    url: finalAnimationURL,
                    data: data,
                    packageURL: finalURL,
                    manifestURL: nil,
                    report: report
                )
            }
        }
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty else {
            throw LottieImportError.emptyFile
        }
        guard data.count <= maximumJSONSize else {
            throw LottieImportError.fileTooLarge
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LottieImportError.invalidJSON
        }

        guard let root = object as? [String: Any] else {
            throw LottieImportError.invalidRoot
        }
        guard root["layers"] is [[String: Any]] else {
            throw LottieImportError.missingField("layers")
        }
        var visited = 0
        try validateNumbers(in: root, depth: 0, visited: &visited)
        var assetIDs = Set<String>()
        var imagePixels = 0.0
        for asset in root["assets"] as? [[String: Any]] ?? [] {
            if let id = asset["id"] as? String, !assetIDs.insert(id).inserted {
                throw LottieImportError.duplicateAssetID(id)
            }
            if asset["p"] != nil, asset["w"] != nil || asset["h"] != nil {
                guard let width = number(asset["w"]), let height = number(asset["h"]),
                      width >= 1, height >= 1, width <= 16384, height <= 16384,
                      width * height <= Double(LottieAssetResolver.maximumImagePixels) else {
                    throw LottieImportError.invalidDimensions
                }
                imagePixels += width * height
                guard imagePixels * 4 <= Double(maximumExpandedArchiveSize) else {
                    throw LottieImportError.numericLimitExceeded
                }
            }
        }

        for field in ["fr", "ip", "op", "w", "h"] where number(root[field]) == nil {
            throw LottieImportError.missingField(field)
        }

        guard let width = number(root["w"]),
              let height = number(root["h"]),
              width > 0,
              height > 0, width.rounded(.towardZero) == width, height.rounded(.towardZero) == height,
              width <= 16384, height <= 16384,
              width * height <= Double(LottieAssetResolver.maximumImagePixels) else {
            throw LottieImportError.invalidDimensions
        }
        guard let frameRate = number(root["fr"]), frameRate > 0, frameRate <= 1000 else {
            throw LottieImportError.invalidFrameRate
        }
        guard let startFrame = number(root["ip"]),
              let endFrame = number(root["op"]),
              endFrame > startFrame, (endFrame - startFrame) / (number(root["fr"]) ?? 1) <= 86400 else {
            throw LottieImportError.invalidFrameRange
        }
    }

    private static func importDotLottie(from sourceURL: URL) async throws -> ImportedLottieFile {
        try await cancellableWork {
            try withSecurityScopedAccess(to: sourceURL) {
                let archiveData = try readBounded(sourceURL, limit: maximumArchiveSize)
                guard !archiveData.isEmpty else {
                    throw LottieImportError.emptyFile
                }
                guard archiveData.count <= maximumArchiveSize else {
                    throw LottieImportError.fileTooLarge
                }

                let finalURL = try uniquePackageDirectoryURL(for: sourceURL)
                let packageURL = finalURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).staging")
                defer { try? FileManager.default.removeItem(at: packageURL) }
                try FileManager.default.createDirectory(
                    at: packageURL,
                    withIntermediateDirectories: true
                )

                do {
                    try DotLottieZipReader.extract(archiveData, to: packageURL)
                    let manifestURL = packageURL.appendingPathComponent("manifest.json")
                    let catalog = try animationCatalog(
                        in: packageURL,
                        manifestURL: manifestURL
                    )
                    let selectedURL = packageURL.appendingPathComponent(catalog.selectedPath)
                    let data = try portableAnimationData(
                        readBounded(selectedURL, limit: maximumJSONSize), sourceURL: selectedURL, packageURL: packageURL
                    )
                    try validate(data)
                    var normalizedURL = packageURL.appendingPathComponent("\(safeBaseName(for: sourceURL)).json")
                    if FileManager.default.fileExists(atPath: normalizedURL.path) {
                        normalizedURL = packageURL.appendingPathComponent("\(safeBaseName(for: sourceURL))-\(UUID().uuidString).json")
                    }
                    try data.write(to: normalizedURL, options: .atomic)
                    let selectedPath = relativePath(from: selectedURL, in: packageURL)
                    let resolvedManifestURL = FileManager.default.fileExists(atPath: manifestURL.path)
                        ? finalURL.appendingPathComponent("manifest.json")
                        : nil
                    try checkPackageBudget(packageURL)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: packageURL, to: finalURL)
                    let finalAnimationURL = finalURL.appendingPathComponent(normalizedURL.lastPathComponent)
                    let report = makeReport(
                        sourceURL: sourceURL,
                        kind: .dotLottie,
                        data: data,
                        packageURL: finalURL,
                        animationURL: finalAnimationURL,
                        manifestURL: resolvedManifestURL,
                        selectedAnimationPath: selectedPath,
                        copiedAssets: [:], animations: catalog.animations, warnings: catalog.warnings
                    )
                    return ImportedLottieFile(
                        url: finalAnimationURL,
                        data: data,
                        packageURL: finalURL,
                        manifestURL: resolvedManifestURL,
                        report: report
                    )
                } catch {
                    try? FileManager.default.removeItem(at: packageURL)
                    throw error
                }
            }
        }
    }

    private static func animationCatalog(
        in packageURL: URL,
        manifestURL: URL
    ) throws -> (animations: [LottiePackageAnimation], selectedPath: String, warnings: [String]) {
        var warnings: [String] = []
        var manifest: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            if let data = try? readBounded(manifestURL, limit: maximumJSONSize),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                manifest = parsed
            } else {
                warnings.append("The manifest is unreadable. Readable animations are listed by path instead.")
            }
        } else {
            warnings.append("No manifest was found. Readable animations are listed by path instead.")
        }
        let declared = manifest["animations"] as? [[String: Any]] ?? []
        let directories = (manifest["version"] as? String)?.hasPrefix("2") == true ? ["a", "animations"] : ["animations", "a"]
        var choices: [LottiePackageAnimation] = []
        var paths = Set<String>()
        var invalidEntries = false
        for animation in declared {
            try Task.checkCancellation()
            let id = animation["id"] as? String ?? ""
            let standard = directories.map { "\($0)/\(id).json" }
            let explicit = ["url", "path", "src"].compactMap { animation[$0] as? String }
            guard let path = (standard + explicit).first(where: {
                guard let url = LottieAssetResolver.fileURL($0, in: packageURL) else { return false }
                return isValidAnimationURL(url)
            }), let normalized = LottieAssetResolver.safeRelativePath(path) else {
                invalidEntries = true
                continue
            }
            if paths.insert(normalized).inserted {
                choices.append(LottiePackageAnimation(animationID: id, title: animation["name"] as? String ?? id, path: normalized))
            } else {
                invalidEntries = true
            }
        }
        let animationURLs = allJSONFiles(in: packageURL)
            .filter { $0.lastPathComponent != "manifest.json" }
            .sorted { left, right in
                let leftPath = left.path.replacingOccurrences(of: packageURL.path, with: "")
                let rightPath = right.path.replacingOccurrences(of: packageURL.path, with: "")
                let leftPriority = animationPathPriority(leftPath)
                let rightPriority = animationPathPriority(rightPath)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                return leftPath < rightPath
            }

        for animationURL in animationURLs {
            try Task.checkCancellation()
            guard let path = relativePath(from: animationURL, in: packageURL), !paths.contains(path),
                  isValidAnimationURL(animationURL) else { continue }
            paths.insert(path)
            let id = animationURL.deletingPathExtension().lastPathComponent
            choices.append(LottiePackageAnimation(animationID: id, title: id, path: path))
        }
        try Task.checkCancellation()
        guard let first = choices.first else { throw LottieImportError.missingDotLottieAnimation }
        let initial = manifest["initial"] as? [String: Any]
        let preferred = initial?["animation"] as? String ?? manifest["activeAnimationId"] as? String
        let selected = preferred.flatMap { id in choices.first { $0.animationID == id } }
        if invalidEntries || (preferred != nil && selected == nil) {
            warnings.append("Some manifest animation entries are missing, duplicated or invalid; only readable animations are available.")
        }
        for (key, directory, message) in [
            ("themes", "t", "Themes are preserved in the package but are not applied by this player."),
            ("stateMachines", "s", "State machines are preserved but are not executed by this player."),
            ("fonts", "f", "Font files are preserved but custom package fonts are not installed by this player."),
        ] {
            if (manifest[key] as? [Any])?.isEmpty == false
                || FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(directory).path)
                || (key == "stateMachines" && initial?["stateMachine"] != nil) {
                warnings.append(message)
            }
        }
        return (choices, (selected ?? first).path, warnings)
    }

    private static func isValidAnimationURL(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? readBounded(url, limit: maximumJSONSize) else {
            return false
        }
        return (try? validate(data)) != nil
    }

    private static func animationPathPriority(_ path: String) -> Int {
        if path.contains("/animations/") { return 0 }
        if path.contains("/a/") { return 1 }
        return 2
    }

    private static func allJSONFiles(in directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "json",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private static func copyExternalAssets(
        referencedBy data: Data,
        originalJSONURL: URL,
        packageURL: URL
    ) throws -> [String: URL] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else {
            return [:]
        }

        var copiedAssets: [String: URL] = [:]
        var remainingBudget = try remainingPackageBudget(at: packageURL, limit: maximumExpandedArchiveSize)
        let sourceDirectory = originalJSONURL.deletingLastPathComponent()
        for asset in assets {
            try Task.checkCancellation()
            let resolution = LottieAssetResolver.resolve(
                name: asset["p"] as? String ?? "", directory: asset["u"] as? String ?? "",
                baseURL: sourceDirectory, assetID: asset["id"] as? String
            )
            guard let sourceURL = resolution.url,
                  let assetPath = resolution.candidatePaths.first,
                  let destinationURL = LottieAssetResolver.fileURL(assetPath, in: packageURL) else { continue }

            if copiedAssets[assetPath] != nil { continue }
            try copyOwnedAsset(from: sourceURL, to: destinationURL, path: assetPath, remainingBudget: &remainingBudget)
            copiedAssets[assetPath] = sourceURL
        }
        return copiedAssets
    }

    private static func findRepairAsset(
        for asset: LottieImportAssetReport,
        in searchDirectory: URL
    ) throws -> URL? {
        let fileNames = Set(([asset.path] + asset.candidatePaths).map {
            ($0 as NSString).lastPathComponent
        }.filter { !$0.isEmpty })

        for candidatePath in asset.candidatePaths {
            try Task.checkCancellation()
            if let url = LottieAssetResolver.fileURL(candidatePath, in: searchDirectory),
               LottieAssetResolver.image(at: url) != nil {
                return url
            }
        }

        for fileName in fileNames {
            try Task.checkCancellation()
            if let url = LottieAssetResolver.fileURL(fileName, in: searchDirectory),
               LottieAssetResolver.image(at: url) != nil {
                return url
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: searchDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let entries = AnySequence<URL> {
            AnyIterator { enumerator.nextObject() as? URL }
        }
        return try findRepairCandidate(in: entries, names: fileNames, directory: searchDirectory)
    }

    static func findRepairCandidate(in entries: AnySequence<URL>, names: Set<String>, directory: URL) throws -> URL? {
        for url in entries {
            try Task.checkCancellation()
            guard names.contains(url.lastPathComponent) else { continue }
            if let relative = relativePath(from: url, in: directory),
               LottieAssetResolver.fileURL(relative, in: directory) != nil,
               LottieAssetResolver.image(at: url) != nil {
                return url
            }
        }

        try Task.checkCancellation()
        return nil
    }

    private static func preferredRepairDestinationPath(
        for asset: LottieImportAssetReport
    ) -> String? {
        if asset.candidatePaths.contains(asset.path) {
            return asset.path
        }
        return asset.candidatePaths.first
    }

    private static func withSecurityScopedAccess<T>(
        to url: URL,
        _ work: () throws -> T
    ) throws -> T {
        // False also occurs for sandbox-owned URLs. Always request the grant;
        // let the read report permission failures, and release only acquired grants.
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }

    private static func uniquePackageDirectoryURL(for sourceURL: URL) throws -> URL {
        let importsURL = FileManager.documentsDirectory()
            .appendingPathComponent(importsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: importsURL, withIntermediateDirectories: true)

        return importsURL.appendingPathComponent(
            "\(safeBaseName(for: sourceURL))-\(UUID().uuidString).flippiepackage", isDirectory: true
        )
    }

    private static func safeBaseName(for sourceURL: URL) -> String {
        let rawName = sourceURL.deletingPathExtension().lastPathComponent
        let sanitizedName = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^A-Za-z0-9А-Яа-я._-]+"#,
                with: "-",
                options: .regularExpression
            )
        // Leave room for UUIDs/extensions, including two-byte Cyrillic names.
        return sanitizedName.isEmpty ? "animation" : String(sanitizedName.prefix(80))
    }

    private static func makeReport(
        sourceURL: URL,
        kind: LottieImportReport.Kind,
        data: Data,
        packageURL: URL,
        animationURL: URL,
        manifestURL: URL?,
        selectedAnimationPath: String?,
        copiedAssets: [String: URL],
        animations: [LottiePackageAnimation] = [],
        warnings: [String] = []
    ) -> LottieImportReport {
        let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let assets = root["assets"] as? [[String: Any]] ?? []
        let packageSummary = packageFileSummary(at: packageURL)
        let imageAssets = assets
            .filter { $0["p"] is String }
            .enumerated()
            .map { index, asset in
                makeAssetReport(
                    index: index,
                    asset: asset,
                    packageURL: packageURL,
                    copiedAssets: copiedAssets
                )
            }

        return LottieImportReport(
            sourceFileName: sourceURL.lastPathComponent,
            kind: kind,
            packageURL: packageURL,
            animationURL: animationURL,
            manifestURL: manifestURL,
            selectedAnimationPath: selectedAnimationPath,
            packageFileCount: packageSummary.fileCount,
            packageSizeBytes: packageSummary.sizeBytes,
            imageAssets: imageAssets,
            animations: animations, warnings: warnings
        )
    }

    private static func makeAssetReport(
        index: Int,
        asset: [String: Any],
        packageURL: URL,
        copiedAssets: [String: URL]
    ) -> LottieImportAssetReport {
        let resolution = LottieAssetResolver.resolve(
            name: asset["p"] as? String ?? "", directory: asset["u"] as? String ?? "",
            baseURL: packageURL, assetID: asset["id"] as? String
        )
        return LottieImportAssetReport(
            id: resolution.assetID ?? "\(index)-\(resolution.path)",
            assetID: resolution.assetID, path: resolution.path, status: resolution.status,
            resolvedURL: resolution.url, candidatePaths: resolution.candidatePaths,
            copiedFromURL: resolution.candidatePaths.compactMap { copiedAssets[$0] }.first
        )
    }

    private static func packageFileSummary(at packageURL: URL) -> (fileCount: Int, sizeBytes: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return (0, 0)
        }

        var fileCount = 0
        var sizeBytes = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            fileCount += 1
            sizeBytes += values.fileSize ?? 0
        }
        return (fileCount, sizeBytes)
    }

    private static func relativePath(from fileURL: URL, in directoryURL: URL) -> String? {
        let directoryPath = directoryURL.standardizedFileURL.path + "/"
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(directoryPath) else { return nil }
        return String(filePath.dropFirst(directoryPath.count))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        return nil
    }

    private static func cancellableWork<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        try Task.checkCancellation()
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            throw LottieImportError.fileTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65536, limit - data.count + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= limit - data.count else { throw LottieImportError.fileTooLarge }
            data.append(chunk)
        }
        return data
    }

    private static func checkPackageBudget(_ url: URL) throws {
        _ = try remainingPackageBudget(at: url, limit: maximumExpandedArchiveSize)
    }

    private static func remainingPackageBudget(at url: URL, limit: Int) throws -> Int {
        let bytes = packageFileSummary(at: url).sizeBytes
        guard bytes <= limit else {
            throw LottieImportError.fileTooLarge
        }
        return limit - bytes
    }

    private static func copyOwnedAsset(from source: URL, to destination: URL, path: String, remainingBudget: inout Int) throws {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LottieImportError.resourceCollision(path)
        }
        // Bound the actual read against remaining capacity BEFORE creating/writing
        // a file; repeated references cannot exceed the package's disk budget.
        let data = try readBounded(source, limit: min(maximumJSONSize, remainingBudget))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        remainingBudget -= data.count
    }

    /// Keep extracted JSON byte-for-byte; only the owned playback copy gets
    /// canonical package-relative image paths (also usable by the SVG fallback).
    private static func portableAnimationData(_ data: Data, sourceURL: URL, packageURL: URL) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var assets = root["assets"] as? [[String: Any]] else { return data }
        var changed = false
        for index in assets.indices {
            try Task.checkCancellation()
            let name = assets[index]["p"] as? String ?? ""
            let directory = assets[index]["u"] as? String ?? ""
            guard !name.hasPrefix("data:"), URL(string: name)?.scheme == nil,
                  URL(string: directory)?.scheme == nil, !name.hasPrefix("/"),
                  !directory.hasPrefix("/"), !name.contains("\0"), !directory.contains("\0") else { continue }
            let resolution = LottieAssetResolver.resolve(name: name, directory: directory, baseURL: packageURL)
            let exact = resolution.candidatePaths.first.flatMap { LottieAssetResolver.fileURL($0, in: packageURL) }
            var resolved = exact.flatMap { LottieAssetResolver.image(at: $0) == nil ? nil : $0 }
            var missingRelativeTarget: URL?
            if resolved == nil {
                let relativeURL = sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(directory.isEmpty ? name : directory + "/" + name).standardizedFileURL
                if let relative = relativePath(from: relativeURL, in: packageURL),
                   let contained = LottieAssetResolver.fileURL(relative, in: packageURL) {
                    missingRelativeTarget = contained
                    if LottieAssetResolver.image(at: contained) != nil { resolved = contained }
                }
            }
            resolved = resolved ?? resolution.url
            let currentPath = LottieAssetResolver.safeRelativePath(directory.isEmpty ? name : directory + "/" + name)
            let target = resolved ?? (currentPath == nil ? missingRelativeTarget : nil)
            guard let target, let relative = relativePath(from: target, in: packageURL) else { continue }
            if currentPath != relative {
                assets[index]["u"] = (relative as NSString).deletingLastPathComponent.isEmpty
                    ? "" : (relative as NSString).deletingLastPathComponent + "/"
                assets[index]["p"] = target.lastPathComponent
                changed = true
            }
        }
        guard changed else { return data }
        root["assets"] = assets
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func validateNumbers(in value: Any, depth: Int, visited: inout Int) throws {
        visited += 1
        guard depth <= 128, visited <= 500_000 else { throw LottieImportError.numericLimitExceeded }
        if visited % 1024 == 0 { try Task.checkCancellation() }
        if let dictionary = value as? [String: Any] {
            for child in dictionary.values {
                try validateNumbers(in: child, depth: depth + 1, visited: &visited)
            }
        } else if let array = value as? [Any] {
            for child in array { try validateNumbers(in: child, depth: depth + 1, visited: &visited) }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite, abs(number.doubleValue) <= 1_000_000_000 else {
                throw LottieImportError.numericLimitExceeded
            }
        }
    }
}

private enum DotLottieZipReader {
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    static func extract(_ data: Data, to destinationURL: URL) throws {
        let entries = try readEntries(from: data)
        var expandedSize = 0
        var paths = Set<String>()

        for entry in entries {
            try Task.checkCancellation()
            guard let safePath = LottieImportServiceSafePath(entry.path) else {
                throw LottieImportError.unsafeArchivePath(entry.path)
            }
            guard paths.insert(safePath.components.joined(separator: "/").lowercased()).inserted else {
                throw LottieImportError.invalidArchive
            }
            let remainingBudget = 300 * 1_024 * 1_024 - expandedSize
            guard entry.uncompressedSize <= remainingBudget else {
                throw LottieImportError.archiveEntryTooLarge(entry.path)
            }

            let fileData = try extract(entry, from: data, remainingBudget: remainingBudget)
            guard fileData.count == entry.uncompressedSize else {
                throw LottieImportError.invalidArchive
            }
            let checksum = fileData.withUnsafeBytes {
                UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(fileData.count)))
            }
            guard checksum == entry.crc else { throw LottieImportError.invalidArchive }
            expandedSize += fileData.count
            if entry.path.hasSuffix("/") {
                guard fileData.isEmpty else { throw LottieImportError.invalidArchive }
                continue
            }

            let fileURL = safePath.components.reduce(destinationURL) { url, component in
                url.appendingPathComponent(component)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Task.checkCancellation()
            try fileData.write(to: fileURL, options: .atomic)
        }
    }

    private static func readEntries(from data: Data) throws -> [Entry] {
        guard let eocdOffset = findEndOfCentralDirectory(in: data),
              data.uint32LE(at: eocdOffset) == endOfCentralDirectorySignature else {
            throw LottieImportError.invalidArchive
        }

        let entryCount = Int(data.uint16LE(at: eocdOffset + 10))
        let centralDirectoryOffset = Int(data.uint32LE(at: eocdOffset + 16))
        let centralDirectorySize = Int(data.uint32LE(at: eocdOffset + 12))
        guard data.uint16LE(at: eocdOffset + 4) == 0,
              data.uint16LE(at: eocdOffset + 6) == 0,
              data.uint16LE(at: eocdOffset + 8) == entryCount,
              eocdOffset + 22 + Int(data.uint16LE(at: eocdOffset + 20)) == data.count,
              entryCount > 0, entryCount <= 10000,
              centralDirectoryOffset + centralDirectorySize == eocdOffset else {
            throw LottieImportError.invalidArchive
        }

        var cursor = centralDirectoryOffset
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            try Task.checkCancellation()
            guard cursor + 46 <= eocdOffset,
                  data.uint32LE(at: cursor) == centralDirectoryHeaderSignature else {
                throw LottieImportError.invalidArchive
            }

            let compressionMethod = Int(data.uint16LE(at: cursor + 10))
            let flags = data.uint16LE(at: cursor + 8)
            let checksum = data.uint32LE(at: cursor + 16)
            let compressedSize32 = data.uint32LE(at: cursor + 20)
            let uncompressedSize32 = data.uint32LE(at: cursor + 24)
            let fileNameLength = Int(data.uint16LE(at: cursor + 28))
            let extraLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let localHeaderOffset32 = data.uint32LE(at: cursor + 42)

            let fileType = (data.uint32LE(at: cursor + 38) >> 16) & 0o170000
            guard flags & 0x0041 == 0, data.uint16LE(at: cursor + 34) == 0,
                  fileType == 0 || fileType == 0o100000 || fileType == 0o040000,
                  compressedSize32 != UInt32.max,
                  uncompressedSize32 != UInt32.max,
                  localHeaderOffset32 != UInt32.max else {
                throw LottieImportError.invalidArchive
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd + extraLength + commentLength <= eocdOffset else {
                throw LottieImportError.invalidArchive
            }
            guard let path = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw LottieImportError.invalidArchive
            }

            entries.append(.init(
                path: path,
                compressionMethod: compressionMethod,
                compressedSize: Int(compressedSize32),
                uncompressedSize: Int(uncompressedSize32),
                localHeaderOffset: Int(localHeaderOffset32),
                flags: flags, crc: checksum, centralDirectoryOffset: centralDirectoryOffset
            ))

            cursor = nameEnd + extraLength + commentLength
        }

        guard cursor == eocdOffset else { throw LottieImportError.invalidArchive }
        return entries
    }

    private static func extract(_ entry: Entry, from data: Data, remainingBudget: Int) throws -> Data {
        let localOffset = entry.localHeaderOffset
        guard localOffset + 30 <= data.count,
              data.uint32LE(at: localOffset) == localFileHeaderSignature else {
            throw LottieImportError.invalidArchive
        }

        let localFileNameLength = Int(data.uint16LE(at: localOffset + 26))
        let localExtraLength = Int(data.uint16LE(at: localOffset + 28))
        let dataStart = localOffset + 30 + localFileNameLength + localExtraLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataStart >= 0,
              dataEnd >= dataStart,
              dataEnd <= entry.centralDirectoryOffset,
              data.uint16LE(at: localOffset + 6) == entry.flags,
              data.uint16LE(at: localOffset + 8) == entry.compressionMethod,
              String(data: data[(localOffset + 30)..<(localOffset + 30 + localFileNameLength)], encoding: .utf8) == entry.path else {
            throw LottieImportError.invalidArchive
        }
        if entry.flags & 8 == 0 {
            guard data.uint32LE(at: localOffset + 14) == entry.crc,
                  data.uint32LE(at: localOffset + 18) == entry.compressedSize,
                  data.uint32LE(at: localOffset + 22) == entry.uncompressedSize else {
                throw LottieImportError.invalidArchive
            }
        }

        let compressedData = data[dataStart..<dataEnd]
        switch entry.compressionMethod {
        case 0:
            guard compressedData.count <= entry.uncompressedSize,
                  compressedData.count <= remainingBudget else {
                throw LottieImportError.archiveEntryTooLarge(entry.path)
            }
            return Data(compressedData)
        case 8:
            return try inflateRawDeflate(
                Data(compressedData),
                expectedSize: entry.uncompressedSize,
                remainingBudget: remainingBudget,
                path: entry.path
            )
        default:
            throw LottieImportError.unsupportedArchiveCompression(entry.path)
        }
    }

    private static func inflateRawDeflate(
        _ data: Data,
        expectedSize: Int,
        remainingBudget: Int,
        path: String
    ) throws -> Data {
        guard !data.isEmpty else {
            throw LottieImportError.invalidArchive
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -15,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw LottieImportError.unsupportedArchiveCompression(path)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(min(expectedSize, 65536))
        var status: Int32 = Z_OK
        let chunkSize = max(64 * 1_024, min(max(expectedSize, 1), 1_024 * 1_024))

        try data.withUnsafeBytes { rawBuffer in
            guard let inputBaseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw LottieImportError.invalidArchive
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                try Task.checkCancellation()
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                var produced = 0
                chunk.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    guard produced <= expectedSize - output.count,
                          produced <= remainingBudget - output.count else {
                        throw LottieImportError.archiveEntryTooLarge(path)
                    }
                    output.append(contentsOf: chunk.prefix(produced))
                }

                guard status == Z_OK || status == Z_STREAM_END else {
                    throw LottieImportError.invalidArchive
                }
            } while status != Z_STREAM_END
        }

        guard output.count == expectedSize, stream.avail_in == 0 else {
            throw LottieImportError.invalidArchive
        }
        return output
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minimumOffset = max(0, data.count - 22 - 65_535)
        var offset = data.count - 22
        while offset >= minimumOffset {
            if data.uint32LE(at: offset) == endOfCentralDirectorySignature {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    private struct Entry {
        let path: String
        let compressionMethod: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let flags: UInt16
        let crc: UInt32
        let centralDirectoryOffset: Int
    }
}

private struct LottieImportServiceSafePath {
    let components: [String]

    init?(_ rawPath: String) {
        guard let path = LottieAssetResolver.safeRelativePath(rawPath) else { return nil }
        components = path.split(separator: "/").map(String.init)
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

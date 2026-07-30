import Foundation
import zlib

struct ImportedLottieFile {
    let url: URL
    let data: Data
    let packageURL: URL
    let manifestURL: URL?
    let report: LottieImportReport
}

struct LottieImportReport: Identifiable, Equatable {
    enum Kind: String, Equatable {
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

struct LottieImportAssetReport: Identifiable, Equatable {
    enum Status: String, Equatable {
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
            "The Lottie width and height must be greater than zero."
        case .invalidFrameRate:
            "The Lottie frame rate must be greater than zero."
        case .invalidFrameRange:
            "The Lottie end frame must be greater than its start frame."
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
        }
    }
}

enum LottieImportService {
    private static let maximumJSONSize = 50 * 1_024 * 1_024
    private static let maximumArchiveSize = 250 * 1_024 * 1_024
    private static let maximumExpandedArchiveSize = 300 * 1_024 * 1_024
    private static let importsDirectoryName = "Flippie Imports"

    static func importAnimation(from sourceURL: URL) async throws -> ImportedLottieFile {
        if sourceURL.pathExtension.lowercased() == "lottie" {
            return try await importDotLottie(from: sourceURL)
        }
        return try await importJSON(from: sourceURL)
    }

    static func repairMissingAssets(
        in report: LottieImportReport,
        from searchDirectory: URL
    ) async throws -> LottieImportReport {
        try await Task.detached(priority: .userInitiated) {
            try withSecurityScopedAccess(to: searchDirectory) {
                let missingAssets = report.imageAssets.filter { $0.status == .missing }
                var copiedAssets: [String: URL] = [:]

                for asset in missingAssets {
                    guard let sourceURL = findRepairAsset(for: asset, in: searchDirectory),
                          let destinationPath = preferredRepairDestinationPath(for: asset) else {
                        continue
                    }

                    let destinationURL = appendingRelativePath(destinationPath, to: report.packageURL)
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    copiedAssets[destinationPath] = sourceURL
                }

                guard !copiedAssets.isEmpty else {
                    throw LottieImportError.noRepairableAssetsFound
                }

                let data = try Data(contentsOf: report.animationURL, options: .mappedIfSafe)
                try validate(data)
                return makeReport(
                    sourceURL: URL(fileURLWithPath: report.sourceFileName),
                    kind: report.kind,
                    data: data,
                    packageURL: report.packageURL,
                    animationURL: report.animationURL,
                    manifestURL: report.manifestURL,
                    selectedAnimationPath: report.selectedAnimationPath,
                    copiedAssets: copiedAssets
                )
            }
        }.value
    }

    static func importJSON(from sourceURL: URL) async throws -> ImportedLottieFile {
        try await Task.detached(priority: .userInitiated) {
            try withSecurityScopedAccess(to: sourceURL) {
                let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                try validate(data)

                let packageURL = try uniquePackageDirectoryURL(for: sourceURL)
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
                let report = makeReport(
                    sourceURL: sourceURL,
                    kind: .json,
                    data: data,
                    packageURL: packageURL,
                    animationURL: destinationURL,
                    manifestURL: nil,
                    selectedAnimationPath: nil,
                    copiedAssets: copiedAssets
                )

                return ImportedLottieFile(
                    url: destinationURL,
                    data: data,
                    packageURL: packageURL,
                    manifestURL: nil,
                    report: report
                )
            }
        }.value
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

        for field in ["fr", "ip", "op", "w", "h"] where number(root[field]) == nil {
            throw LottieImportError.missingField(field)
        }

        guard let width = number(root["w"]),
              let height = number(root["h"]),
              width > 0,
              height > 0 else {
            throw LottieImportError.invalidDimensions
        }
        guard let frameRate = number(root["fr"]), frameRate > 0 else {
            throw LottieImportError.invalidFrameRate
        }
        guard let startFrame = number(root["ip"]),
              let endFrame = number(root["op"]),
              endFrame > startFrame else {
            throw LottieImportError.invalidFrameRange
        }
    }

    private static func importDotLottie(from sourceURL: URL) async throws -> ImportedLottieFile {
        try await Task.detached(priority: .userInitiated) {
            try withSecurityScopedAccess(to: sourceURL) {
                let archiveData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                guard !archiveData.isEmpty else {
                    throw LottieImportError.emptyFile
                }
                guard archiveData.count <= maximumArchiveSize else {
                    throw LottieImportError.fileTooLarge
                }

                let packageURL = try uniquePackageDirectoryURL(for: sourceURL)
                try FileManager.default.createDirectory(
                    at: packageURL,
                    withIntermediateDirectories: true
                )

                do {
                    try DotLottieZipReader.extract(archiveData, to: packageURL)
                    let manifestURL = packageURL.appendingPathComponent("manifest.json")
                    let selectedURL = try selectedDotLottieAnimationURL(
                        in: packageURL,
                        manifestURL: manifestURL
                    )
                    let data = try Data(contentsOf: selectedURL, options: .mappedIfSafe)
                    try validate(data)
                    let normalizedURL = packageURL.appendingPathComponent(
                        "\(safeBaseName(for: sourceURL)).json"
                    )
                    try data.write(to: normalizedURL, options: .atomic)
                    let resolvedManifestURL = FileManager.default.fileExists(atPath: manifestURL.path)
                        ? manifestURL
                        : nil
                    let report = makeReport(
                        sourceURL: sourceURL,
                        kind: .dotLottie,
                        data: data,
                        packageURL: packageURL,
                        animationURL: normalizedURL,
                        manifestURL: resolvedManifestURL,
                        selectedAnimationPath: relativePath(from: selectedURL, in: packageURL),
                        copiedAssets: [:]
                    )
                    return ImportedLottieFile(
                        url: normalizedURL,
                        data: data,
                        packageURL: packageURL,
                        manifestURL: resolvedManifestURL,
                        report: report
                    )
                } catch {
                    try? FileManager.default.removeItem(at: packageURL)
                    throw error
                }
            }
        }.value
    }

    private static func selectedDotLottieAnimationURL(
        in packageURL: URL,
        manifestURL: URL
    ) throws -> URL {
        if FileManager.default.fileExists(atPath: manifestURL.path),
           let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
            let animations = manifest["animations"] as? [[String: Any]] ?? []
            let initial = manifest["initial"] as? [String: Any]
            let initialAnimationID = initial?["animation"] as? String
            let activeID = manifest["activeAnimationId"] as? String
            let preferredIDs = ([initialAnimationID, activeID] + animations.compactMap { $0["id"] as? String })
                .compactMap { $0 }

            for id in preferredIDs {
                guard let safeID = safeRelativePath(id) else { continue }
                for directory in ["animations", "a"] {
                    let animationURL = appendingRelativePath(
                        "\(directory)/\(safeID).json",
                        to: packageURL
                    )
                    if isValidAnimationURL(animationURL) {
                        return animationURL
                    }
                }
            }

            for animation in animations {
                for key in ["url", "path", "src"] {
                    guard let rawPath = animation[key] as? String,
                          let path = safeRelativePath(rawPath) else { continue }
                    let animationURL = appendingRelativePath(path, to: packageURL)
                    if isValidAnimationURL(animationURL) {
                        return animationURL
                    }
                }
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

        for animationURL in animationURLs where isValidAnimationURL(animationURL) {
            return animationURL
        }
        throw LottieImportError.missingDotLottieAnimation
    }

    private static func isValidAnimationURL(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
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
            options: [.skipsHiddenFiles]
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
        let sourceDirectory = originalJSONURL.deletingLastPathComponent()
        for asset in assets {
            guard let assetPath = externalAssetPath(from: asset) else { continue }

            let sourceURL = appendingRelativePath(assetPath, to: sourceDirectory)
            let destinationURL = appendingRelativePath(assetPath, to: packageURL)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            copiedAssets[assetPath] = sourceURL
        }
        return copiedAssets
    }

    private static func findRepairAsset(
        for asset: LottieImportAssetReport,
        in searchDirectory: URL
    ) -> URL? {
        let fileNames = Set(([asset.path] + asset.candidatePaths).map {
            ($0 as NSString).lastPathComponent
        }.filter { !$0.isEmpty })

        for candidatePath in asset.candidatePaths {
            let url = appendingRelativePath(candidatePath, to: searchDirectory)
            if isRegularFile(at: url) {
                return url
            }
        }

        for fileName in fileNames {
            let url = searchDirectory.appendingPathComponent(fileName)
            if isRegularFile(at: url) {
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

        for case let url as URL in enumerator where fileNames.contains(url.lastPathComponent) {
            if isRegularFile(at: url) {
                return url
            }
        }

        return nil
    }

    private static func preferredRepairDestinationPath(
        for asset: LottieImportAssetReport
    ) -> String? {
        if asset.candidatePaths.contains(asset.path) {
            return asset.path
        }
        if let pathWithDirectory = asset.candidatePaths.dropFirst().first {
            return pathWithDirectory
        }
        return asset.candidatePaths.first
    }

    private static func isRegularFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    private static func externalAssetPath(from asset: [String: Any]) -> String? {
        guard let rawFileName = asset["p"] as? String,
              !rawFileName.isEmpty,
              asset["e"] as? Int != 1,
              !rawFileName.hasPrefix("data:"),
              URL(string: rawFileName)?.scheme == nil else {
            return nil
        }

        let rawDirectory = asset["u"] as? String ?? ""
        let joinedPath: String
        if rawDirectory.isEmpty {
            joinedPath = rawFileName
        } else {
            joinedPath = (rawDirectory as NSString).appendingPathComponent(rawFileName)
        }
        return safeRelativePath(joinedPath)
    }

    private static func withSecurityScopedAccess<T>(
        to url: URL,
        _ work: () throws -> T
    ) throws -> T {
        let isLocal = url.path.contains(FileManager.documentsDirectory().path)
            || url.path.contains(Bundle.main.bundlePath)
            || (url.isFileURL && FileManager.default.fileExists(atPath: url.path))
            || FileManager.default.isReadableFile(atPath: url.path)
        let hasAccess = isLocal || url.startAccessingSecurityScopedResource()
        guard hasAccess else {
            throw LottieImportError.accessDenied
        }
        defer {
            if !isLocal {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }

    private static func uniquePackageDirectoryURL(for sourceURL: URL) throws -> URL {
        let importsURL = FileManager.documentsDirectory()
            .appendingPathComponent(importsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: importsURL, withIntermediateDirectories: true)

        let baseName = safeBaseName(for: sourceURL)
        var destination = importsURL.appendingPathComponent(
            "\(baseName).flippiepackage",
            isDirectory: true
        )
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = importsURL.appendingPathComponent(
                "\(baseName)-\(suffix).flippiepackage",
                isDirectory: true
            )
            suffix += 1
        }
        return destination
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
        return sanitizedName.isEmpty ? "animation" : sanitizedName
    }

    private static func safeRelativePath(_ rawPath: String) -> String? {
        let normalizedPath = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedPath.isEmpty,
              !normalizedPath.hasPrefix("/"),
              !normalizedPath.hasPrefix("~"),
              URL(string: normalizedPath)?.scheme == nil else {
            return nil
        }

        let components = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private static func appendingRelativePath(_ relativePath: String, to baseURL: URL) -> URL {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .reduce(baseURL) { url, component in
                url.appendingPathComponent(component)
            }
    }

    private static func makeReport(
        sourceURL: URL,
        kind: LottieImportReport.Kind,
        data: Data,
        packageURL: URL,
        animationURL: URL,
        manifestURL: URL?,
        selectedAnimationPath: String?,
        copiedAssets: [String: URL]
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
            imageAssets: imageAssets
        )
    }

    private static func makeAssetReport(
        index: Int,
        asset: [String: Any],
        packageURL: URL,
        copiedAssets: [String: URL]
    ) -> LottieImportAssetReport {
        let assetID = asset["id"] as? String
        let rawName = asset["p"] as? String ?? ""
        let rawDirectory = asset["u"] as? String ?? ""
        let displayPath = rawDirectory.isEmpty
            ? rawName
            : (rawDirectory as NSString).appendingPathComponent(rawName)
        let reportID = assetID ?? "\(index)-\(displayPath)"

        if rawName.hasPrefix("data:") || asset["e"] as? Int == 1 {
            return LottieImportAssetReport(
                id: reportID,
                assetID: assetID,
                path: rawName.hasPrefix("data:") ? "Embedded image data" : displayPath,
                status: .embedded,
                resolvedURL: nil,
                candidatePaths: [],
                copiedFromURL: nil
            )
        }

        if URL(string: rawName)?.scheme != nil || URL(string: rawDirectory)?.scheme != nil {
            return LottieImportAssetReport(
                id: reportID,
                assetID: assetID,
                path: displayPath,
                status: .remoteUnsupported,
                resolvedURL: nil,
                candidatePaths: [],
                copiedFromURL: nil
            )
        }

        let candidates = imageAssetCandidatePaths(name: rawName, directory: rawDirectory)
        let resolvedURL = candidates
            .map { appendingRelativePath($0, to: packageURL) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let copiedFromURL = candidates.compactMap { copiedAssets[$0] }.first

        return LottieImportAssetReport(
            id: reportID,
            assetID: assetID,
            path: displayPath,
            status: resolvedURL == nil ? .missing : .resolved,
            resolvedURL: resolvedURL,
            candidatePaths: candidates,
            copiedFromURL: copiedFromURL
        )
    }

    private static func imageAssetCandidatePaths(name: String, directory: String) -> [String] {
        let rawCandidates = [
            name,
            directory.isEmpty ? name : (directory as NSString).appendingPathComponent(name),
            ("images" as NSString).appendingPathComponent(name),
            ("i" as NSString).appendingPathComponent(name),
            ("assets" as NSString).appendingPathComponent(name),
        ]

        var result: [String] = []
        var seen = Set<String>()
        for candidate in rawCandidates {
            guard let safePath = safeRelativePath(candidate),
                  seen.insert(safePath).inserted else { continue }
            result.append(safePath)
        }
        return result
    }

    private static func packageFileSummary(at packageURL: URL) -> (fileCount: Int, sizeBytes: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
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
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(directoryPath) else { return nil }
        let relative = filePath.dropFirst(directoryPath.count)
        return relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
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
}

private enum DotLottieZipReader {
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    static func extract(_ data: Data, to destinationURL: URL) throws {
        let entries = try readEntries(from: data)
        var expandedSize = 0

        for entry in entries where !entry.path.hasSuffix("/") {
            guard let safePath = LottieImportServiceSafePath(entry.path) else {
                throw LottieImportError.unsafeArchivePath(entry.path)
            }
            expandedSize += entry.uncompressedSize
            guard expandedSize <= 300 * 1_024 * 1_024 else {
                throw LottieImportError.archiveEntryTooLarge(entry.path)
            }

            let fileData = try extract(entry, from: data)
            guard fileData.count == entry.uncompressedSize else {
                throw LottieImportError.invalidArchive
            }

            let fileURL = safePath.components.reduce(destinationURL) { url, component in
                url.appendingPathComponent(component)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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
        guard centralDirectoryOffset >= 0,
              centralDirectoryOffset < data.count else {
            throw LottieImportError.invalidArchive
        }

        var cursor = centralDirectoryOffset
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  data.uint32LE(at: cursor) == centralDirectoryHeaderSignature else {
                throw LottieImportError.invalidArchive
            }

            let compressionMethod = Int(data.uint16LE(at: cursor + 10))
            let compressedSize32 = data.uint32LE(at: cursor + 20)
            let uncompressedSize32 = data.uint32LE(at: cursor + 24)
            let fileNameLength = Int(data.uint16LE(at: cursor + 28))
            let extraLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let localHeaderOffset32 = data.uint32LE(at: cursor + 42)

            guard compressedSize32 != UInt32.max,
                  uncompressedSize32 != UInt32.max,
                  localHeaderOffset32 != UInt32.max else {
                throw LottieImportError.invalidArchive
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count else {
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
                localHeaderOffset: Int(localHeaderOffset32)
            ))

            cursor = nameEnd + extraLength + commentLength
        }

        return entries
    }

    private static func extract(_ entry: Entry, from data: Data) throws -> Data {
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
              dataEnd <= data.count else {
            throw LottieImportError.invalidArchive
        }

        let compressedData = data[dataStart..<dataEnd]
        switch entry.compressionMethod {
        case 0:
            return Data(compressedData)
        case 8:
            return try inflateRawDeflate(
                Data(compressedData),
                expectedSize: entry.uncompressedSize,
                path: entry.path
            )
        default:
            throw LottieImportError.unsupportedArchiveCompression(entry.path)
        }
    }

    private static func inflateRawDeflate(
        _ data: Data,
        expectedSize: Int,
        path: String
    ) throws -> Data {
        if expectedSize == 0 {
            return Data()
        }
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
        output.reserveCapacity(expectedSize)
        var status: Int32 = Z_OK
        let chunkSize = max(64 * 1_024, min(max(expectedSize, 1), 1_024 * 1_024))

        try data.withUnsafeBytes { rawBuffer in
            guard let inputBaseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw LottieImportError.invalidArchive
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                var produced = 0
                chunk.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }

                guard status == Z_OK || status == Z_STREAM_END else {
                    throw LottieImportError.invalidArchive
                }
            } while status != Z_STREAM_END
        }

        guard output.count == expectedSize else {
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
    }
}

private struct LottieImportServiceSafePath {
    let components: [String]

    init?(_ rawPath: String) {
        let normalizedPath = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedPath.isEmpty,
              !normalizedPath.hasPrefix("/"),
              !normalizedPath.hasPrefix("~"),
              URL(string: normalizedPath)?.scheme == nil else {
            return nil
        }

        let components = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return nil
        }
        self.components = components
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

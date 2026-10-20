import Foundation
import SwiftUI

/// An in-process resource lease, not serialized metadata. A live document or
/// queued snapshot in another window must outlive cleanup of the last-project
/// pointer. The registry lock is independent of the store lock; it never calls
/// back into ProjectStore, so the lock order cannot be reversed.
final class ProjectSourceLease: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private let key: String

    init(source: URL) {
        key = source.resolvingSymlinksInPath().standardizedFileURL.path
        Self.lock.withLock { Self.counts[key, default: 0] += 1 }
    }
    deinit {
        Self.lock.withLock {
            let remaining = (Self.counts[key] ?? 1) - 1
            if remaining == 0 { Self.counts.removeValue(forKey: key) }
            else { Self.counts[key] = remaining }
        }
    }
    static func isHeld(_ url: URL) -> Bool {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        return lock.withLock { (counts[key] ?? 0) > 0 }
    }
}

actor ProjectStore {
    func quarantineDamagedProject(at url: URL) async throws -> URL {
        try Self.access.withLock {
            do {
                _ = try read(from: url)
                throw ProjectStoreError.recoveryNotNeeded
            } catch ProjectStoreError.unsupportedSchema(let version) {
                throw ProjectStoreError.unsupportedSchema(version)
            } catch ProjectStoreError.recoveryNotNeeded { throw ProjectStoreError.recoveryNotNeeded }
            catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == NSFileReadNoPermissionError { throw error }
            }
            try Task.checkCancellation()
            let backup = url.deletingLastPathComponent().appendingPathComponent("Recovered-" + UUID().uuidString + ".flippie")
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        }
    }
    // The app has one store; the lock also serializes independent store instances
    // in the same process so load cannot race source cleanup or manifest commit.
    private static let access = NSLock()
    static var lastProjectURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flippie/Last.flippie", isDirectory: true)
    }

    func save(_ project: FlippieProject, at url: URL) async throws {
        try Self.access.withLock { try write(project, at: url) }
    }

    func load(from url: URL) async throws -> FlippieProject {
        try Self.access.withLock { try read(from: url) }
    }

    private func write(_ snapshot: FlippieProject, at url: URL) throws {
        try Task.checkCancellation()
        try snapshot.validate()
        try LottieImportService.validate(snapshot.originalData)
        guard url.isFileURL else { throw ProjectStoreError.invalidProject }
        try directory(url)
        let manifest = url.appendingPathComponent("project.json")
        // Do not silently downgrade an existing project from a future app.
        if FileManager.default.fileExists(atPath: manifest.path) {
            let prior = try read(from: url)
            if prior.id == snapshot.id && prior.revision > snapshot.revision { throw ProjectStoreError.staleSnapshot }
        }
        let sources = url.appendingPathComponent("Sources", isDirectory: true)
        try directory(sources)
        // This lock covers every writer in this app process. No active copy
        // can own another staging directory here; these are interrupted saves.
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            if name.hasPrefix(".staging-"), UUID(uuidString: String(name.dropFirst(9))) != nil {
                try FileManager.default.removeItem(at: file)
            }
        }
        let target = sources.appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
        let staging = sources.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var project = snapshot
        if FileManager.default.fileExists(atPath: target.path) {
            let original = try contained(project.originalPath, in: url)
            guard try bounded(original, limit: 50 * 1024 * 1024) == project.originalData else {
                throw ProjectStoreError.invalidProject
            }
            let assets = try contained(project.assetDirectory, in: url)
            project.resourcePaths = try resources(in: assets).map(\.path)
        } else {
            try directory(staging)
            let assets = staging.appendingPathComponent("assets", isDirectory: true)
            try directory(assets)
            if let base = project.assetBaseURL {
                let files = try referencedResources(data: project.originalData, in: base)
                for file in files {
                    try Task.checkCancellation()
                    let destination = assets.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file.url, to: destination)
                }
                project.resourcePaths = files.map(\.path)
            }
            try project.originalData.write(to: staging.appendingPathComponent("original.json"), options: .atomic)
            // Use exactly the loader's entry budget, including directories,
            // before the manifest can commit a package that must reopen.
            let copied = try resources(in: assets)
            guard Set(copied.map(\.path)) == Set(project.resourcePaths) else { throw ProjectStoreError.invalidProject }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: target)
        }
        try project.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let metadata = try encoder.encode(project)
        guard metadata.count <= 2 * 1024 * 1024 else { throw ProjectStoreError.resourceLimit }
        try Task.checkCancellation()
        // This is the only commit point. Previous JSON/resources stay untouched
        // until the complete new source exists and the metadata rename succeeds.
        try metadata.write(to: manifest, options: .atomic)
        pruneSources(in: sources, keeping: project.id.uuidString)
    }

    private func read(from url: URL) throws -> FlippieProject {
        try Task.checkCancellation()
        let metadata = try bounded(try contained("project.json", in: url), limit: 2 * 1024 * 1024)
        guard let root = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let version = root["schemaVersion"] as? Int else { throw ProjectStoreError.invalidProject }
        guard version == 1 else { throw ProjectStoreError.unsupportedSchema(version) }
        var project = try JSONDecoder().decode(FlippieProject.self, from: metadata)
        try project.validate()
        let original = try contained(project.originalPath, in: url)
        project.originalData = try bounded(original, limit: 50 * 1024 * 1024)
        try LottieImportService.validate(project.originalData)
        let assets = try contained(project.assetDirectory, in: url)
        let actual = try resources(in: assets)
        guard Set(actual.map(\.path)) == Set(project.resourcePaths) else { throw ProjectStoreError.invalidProject }
        project.originalURL = original; project.assetBaseURL = assets
        project.sourceLease = ProjectSourceLease(source: original.deletingLastPathComponent())
        return project
    }

    private func contained(_ path: String, in root: URL) throws -> URL {
        guard root.isFileURL,
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let url = LottieAssetResolver.fileURL(path, in: root) else { throw ProjectStoreError.invalidProject }
        // Reject symlink components even when they resolve elsewhere inside the package.
        var candidate = root
        for part in path.split(separator: "/") {
            candidate.appendPathComponent(String(part))
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ProjectStoreError.invalidProject
            }
        }
        return url
    }

    private func directory(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ProjectStoreError.invalidProject
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func bounded(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes <= limit else { throw ProjectStoreError.resourceLimit }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ProjectStoreError.resourceLimit }
        return data
    }

    private func resources(in root: URL) throws -> [(path: String, url: URL)] {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProjectStoreError.invalidProject }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, error in enumerationError = error; return false }) else { throw ProjectStoreError.invalidProject }
        let prefix = root.standardizedFileURL.path + "/"
        var result: [(String, URL)] = []; var total = 0; var entries = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation(); entries += 1
            guard entries <= 4096, file.standardizedFileURL.path.hasPrefix(prefix) else { throw ProjectStoreError.resourceLimit }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ProjectStoreError.invalidProject }
            guard values.isRegularFile == true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(prefix.count))
            guard LottieAssetResolver.safeRelativePath(relative) == relative,
                  let bytes = values.fileSize, bytes <= 50 * 1024 * 1024 else { throw ProjectStoreError.resourceLimit }
            total += bytes
            guard total <= 300 * 1024 * 1024 else { throw ProjectStoreError.resourceLimit }
            result.append((relative, try contained(relative, in: root)))
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.0 < $1.0 }
    }

    private func referencedResources(data: Data, in base: URL) throws -> [(path: String, url: URL)] {
        let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectStoreError.invalidProject
        }
        var paths = Set<String>()
        for asset in root["assets"] as? [[String: Any]] ?? [] {
            guard let name = asset["p"] as? String, !name.hasPrefix("data:") else { continue }
            let directory = asset["u"] as? String ?? ""
            let resolved = LottieAssetResolver.resolve(name: name, directory: directory, baseURL: base)
            if let imageURL = resolved.url {
                let prefix = base.standardizedFileURL.path + "/"
                guard imageURL.standardizedFileURL.path.hasPrefix(prefix) else { throw ProjectStoreError.invalidProject }
                paths.insert(String(imageURL.standardizedFileURL.path.dropFirst(prefix.count)))
                continue
            }
            let candidates = LottieAssetResolver.candidatePaths(name: name, directory: directory)
            for candidate in candidates {
                let url = try contained(candidate, in: base)
                if FileManager.default.fileExists(atPath: url.path) { paths.insert(candidate); break }
            }
        }
        let fonts = (root["fonts"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        for font in fonts {
            guard let path = font["fPath"] as? String, LottieAssetResolver.safeRelativePath(path) == path else { continue }
            let url = try contained(path, in: base)
            if FileManager.default.fileExists(atPath: url.path) { paths.insert(path) }
        }
        guard paths.count <= 4096 else { throw ProjectStoreError.resourceLimit }
        var total = 0
        return try paths.sorted().map { path in
            let url = try contained(path, in: base)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let bytes = values.fileSize,
                  bytes <= 50 * 1024 * 1024 else { throw ProjectStoreError.resourceLimit }
            total += bytes
            guard total <= 300 * 1024 * 1024 else { throw ProjectStoreError.resourceLimit }
            return (path, url)
        }
    }

    private func pruneSources(in sources: URL, keeping id: String) {
        // Keep current + one prior source. Cleanup is post-commit and never
        // makes a successfully written current manifest point at deleted data.
        let files = (try? FileManager.default.contentsOfDirectory(at: sources,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let old = files.filter {
            $0.lastPathComponent != id && UUID(uuidString: $0.lastPathComponent) != nil && !ProjectSourceLease.isHeld($0)
        }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for file in old.dropFirst() { try? FileManager.default.removeItem(at: file) }
    }
}

@MainActor
final class ProjectPersistenceCoordinator: ObservableObject {
    let url: URL
    private let store = ProjectStore()
    private var pending: Task<Void, Error>?
    @Published private(set) var isRecovering = false
    init(url: URL = ProjectStore.lastProjectURL) { self.url = url }

    func enqueue(_ document: AnimationDocument, allowPendingEdits: Bool = false) throws -> Task<Void, Error> {
        guard !isRecovering else { throw ProjectStoreError.editInProgress }
        var snapshot = try document.projectSnapshot(allowPendingEdits: allowPendingEdits)
        // Protect the destination before the actor hop, including the gap
        // between an atomic commit and the main actor adopting its location.
        snapshot.sourceLease = ProjectSourceLease(source: url.appendingPathComponent(snapshot.originalPath).deletingLastPathComponent())
        let predecessor = pending; let store = store; let url = url
        let task = Task { @MainActor [weak document] in
            // A failed prior save must not permanently poison later attempts.
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            try await store.save(snapshot, at: url)
            document?.didSave(snapshot, at: url)
        }
        pending = task
        return task
    }

    func save(_ document: AnimationDocument, allowPendingEdits: Bool = false) async throws {
        let task = try enqueue(document, allowPendingEdits: allowPendingEdits)
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func restore(document: AnimationDocument, session: PlaybackSession) async throws -> Bool {
        guard !document.isLoaded, !session.hasAnimation,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else { return false }
        let project = try await store.load(from: url)
        try Task.checkCancellation()
        guard !document.isLoaded, !session.hasAnimation else { return false }
        let candidate = AnimationDocument(); try candidate.load(project: project)
        guard let data = candidate.renderedData else { throw AnimationDocumentError.invalidRootObject }
        try await session.load(data: data, runtime: project.runtime, baseURL: project.assetBaseURL)
        try document.load(project: project)
        session.speed = project.edits.playbackSpeed; session.loopMode = project.loopMode
        return true
    }

    func canRecoverSavedProject() async -> Bool {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else { return false }
        do { _ = try await store.load(from: url); return false }
        catch ProjectStoreError.unsupportedSchema { return false }
        catch is CancellationError { return false }
        catch {
            return !((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoPermissionError)
        }
    }

    func recoverDamagedProject(document: AnimationDocument) async throws -> URL {
        guard !isRecovering else { throw ProjectStoreError.editInProgress }
        isRecovering = true; defer { isRecovering = false }
        _ = try? await pending?.value
        let backup = try await store.quarantineDamagedProject(at: url)
        document.relocateProjectFiles(from: url, to: backup)
        return backup
    }
}

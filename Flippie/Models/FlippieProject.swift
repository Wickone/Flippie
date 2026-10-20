import Foundation

struct FlippieProject: Codable {
    var schemaVersion = 1
    var id: UUID
    var revision: Int
    var displayName: String
    var originalPath: String
    var assetDirectory: String
    var resourcePaths: [String] = []
    var edits: AnimationEdits
    var runtime: LottieRuntimeVersion
    var loopMode: PlayerLoopMode
    var originalData = Data()
    var originalURL: URL?
    var assetBaseURL: URL?
    var sourceLease: ProjectSourceLease?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, revision, displayName, originalPath, assetDirectory
        case resourcePaths, edits, runtime, loopMode
    }

    init(id: UUID, revision: Int, displayName: String, originalData: Data,
         assetBaseURL: URL?, edits: AnimationEdits, runtime: LottieRuntimeVersion,
         loopMode: PlayerLoopMode) {
        self.id = id; self.revision = revision; self.displayName = displayName
        self.originalPath = "Sources/\(id.uuidString)/original.json"
        self.assetDirectory = "Sources/\(id.uuidString)/assets"
        self.originalData = originalData; self.assetBaseURL = assetBaseURL
        self.edits = edits; self.runtime = runtime; self.loopMode = loopMode
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw ProjectStoreError.unsupportedSchema(schemaVersion) }
        guard revision >= 0, displayName.utf8.count <= 1024,
              originalPath == "Sources/\(id.uuidString)/original.json",
              assetDirectory == "Sources/\(id.uuidString)/assets",
              resourcePaths.count <= 4096, Set(resourcePaths).count == resourcePaths.count,
              resourcePaths.allSatisfy({ LottieAssetResolver.safeRelativePath($0) == $0 }) else {
            throw ProjectStoreError.invalidProject
        }
        try edits.validate()
    }
}

enum ProjectStoreError: LocalizedError {
    case unsupportedSchema(Int), invalidProject, invalidEdits, resourceLimit, staleSnapshot, editInProgress, recoveryNotNeeded
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "This project uses unsupported version \(version). The saved project was not changed."
        case .invalidProject: "The saved project or its resource paths are damaged."
        case .invalidEdits: "The project contains invalid colors or playback speed."
        case .resourceLimit: "The project exceeds the resource safety limit (300 MiB, 4096 files)."
        case .staleSnapshot: "A newer revision of this project has already been saved."
        case .editInProgress: "Finish applying changes before saving the project."
        case .recoveryNotNeeded: "This saved project is valid and does not need recovery."
        }
    }
}

extension AnimationEdits {
    func validate() throws {
        func valid(_ color: RGBAColor, unit: Bool) -> Bool {
            color.components.allSatisfy { $0.isFinite && (!unit || (0...1).contains($0)) }
        }
        guard playbackSpeed.isFinite, (0.1...3).contains(playbackSpeed), colorReplacements.count <= 4096,
              colorReplacements.allSatisfy({ valid($0.key, unit: false) && valid($0.value, unit: true) }),
              backgroundColor.map({ valid($0, unit: true) }) ?? true else { throw ProjectStoreError.invalidEdits }
    }
}

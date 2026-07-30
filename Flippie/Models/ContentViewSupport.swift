import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let dotLottie = UTType(filenameExtension: "lottie", conformingTo: .zip)
        ?? UTType(filenameExtension: "lottie")
        ?? .data
}

enum PlaybackControlSymbol {
    case system(String)
    case skipBackward
    case skipForward
}

enum LoadedActionTab: Int, CaseIterable, Identifiable, Hashable {
    case preview
    case edit
    case export

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .preview:
            return "Preview"
        case .edit:
            return "Edit"
        case .export:
            return "Export"
        }
    }

    var systemName: String {
        switch self {
        case .preview:
            return "play.circle.fill"
        case .edit:
            return "gearshape.fill"
        case .export:
            return "square.and.arrow.up"
        }
    }
}

struct LottieCompatibilityResult: Identifiable, Equatable {
    enum Status: Equatable {
        case passed
        case fallback
        case failed
    }

    let id: String
    let runtime: LottieRuntimeVersion
    let status: Status
    let rendererName: String
    let frameRangeDescription: String?
    let message: String?

    init(
        runtime: LottieRuntimeVersion,
        status: Status,
        rendererName: String,
        frameRangeDescription: String? = nil,
        message: String? = nil
    ) {
        id = runtime.rawValue
        self.runtime = runtime
        self.status = status
        self.rendererName = rendererName
        self.frameRangeDescription = frameRangeDescription
        self.message = message
    }
}

enum FileImportMode {
    case animation
    case assetRepair

    var allowedContentTypes: [UTType] {
        switch self {
        case .animation:
            return [.json, .dotLottie]
        case .assetRepair:
            return [.folder]
        }
    }
}

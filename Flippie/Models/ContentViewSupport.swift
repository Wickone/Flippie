import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct LottiePackageAnimation: Identifiable, Equatable, Sendable {
    let animationID: String
    let title: String
    let path: String

    var id: String { path }
}

struct LottieAnimationPickerSheet: View {
    let animations: [LottiePackageAnimation]
    let selectedPath: String?
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List(animations) { animation in
                Button {
                    onSelect(animation.path)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(animation.title.isEmpty ? animation.animationID : animation.title)
                                .foregroundStyle(.primary)
                            Text(animation.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if animation.path == selectedPath {
                            Image(systemName: "checkmark").accessibilityLabel("Default animation")
                        }
                    }
                }
            }
            .navigationTitle("Choose animation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

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

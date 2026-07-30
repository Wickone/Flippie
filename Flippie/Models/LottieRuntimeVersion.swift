import Foundation

enum LottieRuntimeVersion: String, CaseIterable, Identifiable, Codable {
    case v300 = "3.0.0"
    case v350 = "3.5.0"
    case v400 = "4.0.0"
    case v461 = "4.6.1"

    static let embedded: LottieRuntimeVersion = .v461

    var id: String { rawValue }

    var title: String {
        "Lottie \(rawValue)"
    }

    var shortTitle: String {
        switch self {
        case .v300: "3.0"
        case .v350: "3.5"
        case .v400: "4.0"
        case .v461: "4.6"
        }
    }

    var comparisonNote: String {
        switch self {
        case .v300:
            return "First Swift-only 3.x renderer baseline"
        case .v350:
            return "Last 3.x release before the 4.0 renderer transition"
        case .v400:
            return "Initial 4.x renderer and API transition"
        case .v461:
            return "Current stable iOS comparison runtime"
        }
    }
}

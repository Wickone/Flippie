import SwiftUI

enum SheetRoute: Identifiable {
    case bundledAnimations, edit, export, rendererComparison, playbackSettings, emptyCopy
    case importReport(LottieImportReport)
    case animationPicker(ImportedLottieFile)

    var id: String {
        switch self {
        case .bundledAnimations: "bundled"
        case .edit: "edit"
        case .export: "export"
        case .rendererComparison: "comparison"
        case .playbackSettings: "playback"
        case .emptyCopy: "copy"
        case .importReport(let report): "report-\(report.id)"
        case .animationPicker(let file): "picker-\(file.id)"
        }
    }
}

@MainActor
final class SheetCoordinator: ObservableObject {
    @Published private(set) var active: SheetRoute?
    private var pending: SheetRoute?
    private var isDismissing = false
    private var dismissingRoute: SheetRoute?

    func present(_ route: SheetRoute) {
        if active != nil || isDismissing {
            pending = route
            dismiss()
        } else {
            active = route
        }
    }
    func dismiss() {
        if let active { dismissingRoute = active }
        isDismissing = active != nil || isDismissing
        active = nil
    }
    @discardableResult
    func didDismiss() -> SheetRoute? {
        let dismissed = dismissingRoute
        dismissingRoute = nil
        isDismissing = false
        if let pending {
            self.pending = nil
            active = pending
        }
        return dismissed
    }
}

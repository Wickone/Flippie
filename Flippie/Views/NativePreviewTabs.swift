import SwiftUI
import UIKit

enum NativePreviewPlacement {
    static let phoneLift: CGFloat = 40
    static func lift(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        idiom == .phone ? phoneLift : 0
    }
}

/// UIKit owns the bar's material, fonts, geometry, selection and touch tracking.
/// The two commands deliberately do not replace the selected live preview.
struct NativePreviewTabs<Preview: View>: UIViewControllerRepresentable {
    let onCommand: (LoadedActionTab) -> Void
    @ViewBuilder let preview: () -> Preview

    func makeUIViewController(context: Context) -> RaisedPreviewContainer<Preview> {
        RaisedPreviewContainer(preview: preview(), onCommand: onCommand)
    }

    func updateUIViewController(_ controller: RaisedPreviewContainer<Preview>, context: Context) {
        controller.tabs.previewHost.rootView = preview()
        controller.tabs.onCommand = onCommand
    }
}

/// Only the child controller's root view is positioned here. UIKit still owns
/// the tab bar's frame, material, selection animation and gesture handling.
final class RaisedPreviewContainer<Preview: View>: UIViewController {
    let tabs: NativePreviewTabController<Preview>
    private var bottomConstraint: NSLayoutConstraint?

    init(preview: Preview, onCommand: @escaping (LoadedActionTab) -> Void) {
        tabs = NativePreviewTabController(preview: preview, onCommand: onCommand)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(preview:onCommand:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        addChild(tabs)
        tabs.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabs.view)
        let bottom = tabs.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottomConstraint = bottom
        NSLayoutConstraint.activate([
            tabs.view.topAnchor.constraint(equalTo: view.topAnchor),
            tabs.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom
        ])
        tabs.didMove(toParent: self)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // iPad owns the placement of its top tab bar; only raise the iPhone bar.
        let lift = min(NativePreviewPlacement.lift(for: traitCollection.userInterfaceIdiom), max(0, view.bounds.height))
        if bottomConstraint?.constant != -lift { bottomConstraint?.constant = -lift }
        // A shorter child no longer intersects the home-indicator area. Restore
        // that lost inset so the native bar moves up without changing its height.
        let bottomInset = min(lift, view.safeAreaInsets.bottom)
        if tabs.additionalSafeAreaInsets.bottom != bottomInset {
            var insets = tabs.additionalSafeAreaInsets
            insets.bottom = bottomInset
            tabs.additionalSafeAreaInsets = insets
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }
}

final class NativePreviewTabController<Preview: View>: UITabBarController, UITabBarControllerDelegate {
    let previewHost: UIHostingController<Preview>
    var onCommand: (LoadedActionTab) -> Void

    init(preview: Preview, onCommand: @escaping (LoadedActionTab) -> Void) {
        self.previewHost = UIHostingController(rootView: preview)
        self.onCommand = onCommand
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .light
        traitOverrides.userInterfaceStyle = .light
        view.backgroundColor = .clear
        previewHost.view.backgroundColor = .clear
        previewHost.view.isOpaque = false
        tabBar.overrideUserInterfaceStyle = .light
        tabBar.traitOverrides.userInterfaceStyle = .light
        tabBar.barStyle = .default
        if #available(iOS 18.0, *) { mode = .tabBar }
        let controllers = [previewHost, UIViewController(), UIViewController()]
        for (index, controller) in controllers.enumerated() {
            let tab = LoadedActionTab.allCases[index]
            controller.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.systemName), tag: tab.rawValue)
            controller.tabBarItem.accessibilityIdentifier = "tab-\(tab.title.lowercased())"
        }
        setViewControllers(controllers, animated: false)
        selectedIndex = 0
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(preview:onCommand:)") }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let tab = LoadedActionTab(rawValue: viewController.tabBarItem.tag) else { return false }
        guard tab == .preview else { onCommand(tab); return false }
        return true
    }
}

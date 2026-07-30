import SwiftUI
import UIKit

@main
struct FlippieApp: App {
    init() {
        UITabBar.appearance().barStyle = .default
        UITabBar.appearance().isTranslucent = true
        UITabBar.appearance().overrideUserInterfaceStyle = .light
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.colorScheme, .light)
                .preferredColorScheme(.light)
        }
    }
}

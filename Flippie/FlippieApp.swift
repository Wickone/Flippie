import SwiftUI
import UIKit

@main
struct FlippieApp: App {
    var body: some Scene {
        WindowGroup {
            appContent
                .environment(\.colorScheme, .light)
                .preferredColorScheme(.light)
        }
    }

    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTesting"),
           ProcessInfo.processInfo.arguments.contains("-uiCompactViewport") {
            ContentView().frame(width: 320, height: 568)
        } else { ContentView() }
        #else
        ContentView()
        #endif
    }
}

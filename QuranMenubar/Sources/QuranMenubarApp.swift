import SwiftUI
import AppKit

@main
struct QuranMenubarApp: App {
    @NSApplicationDelegateAdaptor(MenuController.self) private var appDelegate

    init() {
        UserDefaults.standard.register(defaults: [
            "resumeLastPosition": true,
            "maxCacheBytes": 2_147_483_648, // ≈ 2 Go
            "disableStreaming": true,
            "debugShowDockIcon": false
        ])
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

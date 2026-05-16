import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "VisionPOC Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

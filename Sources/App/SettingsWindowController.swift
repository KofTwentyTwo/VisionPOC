import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let frameDefaultsKey = "VPOC.SettingsWindowFrame"

    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "VisionPOC Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.delegate = self
        restoreFrame()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func restoreFrame() {
        guard let window,
              let saved = UserDefaults.standard.string(forKey: SettingsWindowController.frameDefaultsKey) else {
            return
        }
        let rect = NSRectFromString(saved)
        if rect.size.width > 0 && rect.size.height > 0 {
            window.setFrame(rect, display: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame),
                                  forKey: SettingsWindowController.frameDefaultsKey)
    }
}

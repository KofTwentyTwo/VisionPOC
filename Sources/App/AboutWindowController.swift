import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    nonisolated(unsafe) private static let frameDefaultsKey = "VPOC.AboutWindowFrame"

    init() {
        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "About VisionPOC"
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
              let saved = UserDefaults.standard.string(forKey: AboutWindowController.frameDefaultsKey) else {
            return
        }
        let rect = NSRectFromString(saved)
        if rect.size.width > 0 && rect.size.height > 0 {
            window.setFrame(rect, display: false)
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame),
                                  forKey: AboutWindowController.frameDefaultsKey)
    }
}

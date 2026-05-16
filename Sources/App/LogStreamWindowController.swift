import AppKit
import SwiftUI

@MainActor
final class LogStreamWindowController: NSWindowController, NSWindowDelegate {
    private static let frameDefaultsKey = "VPOC.LogWindowFrame"

    init() {
        let hosting = NSHostingController(rootView: LogStreamView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "VisionPOC Log Stream"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
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
              let saved = UserDefaults.standard.string(forKey: LogStreamWindowController.frameDefaultsKey) else {
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
                                  forKey: LogStreamWindowController.frameDefaultsKey)
    }
}

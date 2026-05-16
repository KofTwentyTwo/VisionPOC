import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static let frameDefaultsKey = "VPOC.HistoryWindowFrame"

    init() {
        let hosting = NSHostingController(rootView: HistoryView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "VisionPOC Detection History"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.level = .floating
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
              let saved = UserDefaults.standard.string(forKey: HistoryWindowController.frameDefaultsKey) else {
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
                                  forKey: HistoryWindowController.frameDefaultsKey)
    }
}

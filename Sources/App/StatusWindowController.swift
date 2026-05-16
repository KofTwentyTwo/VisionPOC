import AppKit
import SwiftUI

@MainActor
final class StatusWindowController: NSWindowController, NSWindowDelegate {
    nonisolated(unsafe) private static let frameDefaultsKey = "VPOC.StatusWindowFrame"

    init(detectorAccess: @escaping @MainActor () -> DetectorSnapshot?) {
        let hosting = NSHostingController(rootView: StatusView(detectorAccess: detectorAccess))
        let window = NSWindow(contentViewController: hosting)
        window.title = "VisionPOC Status"
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
              let saved = UserDefaults.standard.string(forKey: StatusWindowController.frameDefaultsKey) else {
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
                                  forKey: StatusWindowController.frameDefaultsKey)
    }
}

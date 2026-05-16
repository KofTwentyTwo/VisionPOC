import AppKit
import SwiftUI

@MainActor
final class LogStreamWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: LogStreamView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "VisionPOC Log Stream"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

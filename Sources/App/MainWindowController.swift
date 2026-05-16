import AppKit
import MetalKit

final class MainWindowController: NSWindowController {
    private let mtkView: MTKView
    private let capture: CameraCapture
    let detector: ObjectDetector
    private let edgePass: EdgePass
    private let jarvisPass: JarvisStylePass
    private let asciiPass: AsciiPass
    private let renderer: Renderer

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required: no default system device available.")
        }

        let defaultSize = Theme.Layout.defaultWindowSize
        let minSize = Theme.Layout.minWindowSize

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "VisionPOC"
        window.minSize = minSize
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()

        let view = MTKView(frame: NSRect(origin: .zero, size: defaultSize), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = Int(Theme.Tick.renderFPS)
        view.framebufferOnly = true
        let bg = Theme.Palette.background
        view.clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))
        view.autoResizeDrawable = true
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        self.mtkView = view

        let capture = CameraCapture(device: device)
        let detector = ObjectDetector()
        let edgePass = EdgePass(device: device)
        let jarvisPass = JarvisStylePass()
        guard let asciiPass = AsciiPass(device: device) else {
            fatalError("Failed to build the ASCII atlas.")
        }

        guard let renderer = Renderer(
            view: view,
            device: device,
            capture: capture,
            detector: detector,
            edgePass: edgePass,
            jarvisPass: jarvisPass,
            asciiPass: asciiPass
        ) else {
            fatalError("Failed to initialize Renderer.")
        }

        self.capture = capture
        self.detector = detector
        self.edgePass = edgePass
        self.jarvisPass = jarvisPass
        self.asciiPass = asciiPass
        self.renderer = renderer

        view.delegate = renderer

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        Task { await capture.start() }
    }
}

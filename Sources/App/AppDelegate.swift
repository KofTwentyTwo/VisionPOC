import AppKit
import AVFoundation
import CoreText
import Metal
import SwiftUI
import Vision

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @unchecked Sendable {
    private var windowController: MainWindowController?
    @MainActor private var settingsController: SettingsWindowController?
    @MainActor private var logController: LogStreamWindowController?
    @MainActor private var historyController: HistoryWindowController?
    @MainActor private var statusController: StatusWindowController?
    @MainActor private var cameraDevicesSubmenu: NSMenu?
    @MainActor private var recorder: Recorder?
    @MainActor private var privacyMenuItem: NSMenuItem?
    @MainActor private var recordMenuItem: NSMenuItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogStream.shared.log("VisionPOC starting up", level: .info, source: .app)
        AppDelegate.registerBundledFonts()

        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)

        // Wake the history store so it starts subscribing to the event bus
        // immediately, before the History window has ever been opened.
        _ = HistoryStore.shared

        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        LogStream.shared.log("ready — main window shown", level: .info, source: .app)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // -----------------------------------------------------------------
        // Application menu (VisionPOC): app-level commands only — Settings,
        // Hide, Quit. Convention: Mac apps put their config and
        // lifecycle here, NOT everything that doesn't fit elsewhere.
        // -----------------------------------------------------------------
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("Settings…", action: #selector(openSettings(_:)), key: ",", mods: [.command]))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Hide \(appName)", action: #selector(NSApplication.hide(_:)), key: "h", mods: [.command], target: NSApp))
        let hideOthers = menuItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option], target: NSApp)
        appMenu.addItem(hideOthers)
        appMenu.addItem(menuItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), key: "", mods: [], target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Quit \(appName)", action: #selector(NSApplication.terminate(_:)), key: "q", mods: [.command]))
        appMenuItem.submenu = appMenu

        // -----------------------------------------------------------------
        // File menu — actions that write something to disk.
        // -----------------------------------------------------------------
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("Save Snapshot", action: #selector(saveSnapshot(_:)), key: "s", mods: [.command]))
        let record = menuItem("Start Recording", action: #selector(toggleRecording(_:)), key: "r", mods: [.command, .shift])
        fileMenu.addItem(record)
        recordMenuItem = record
        fileItem.submenu = fileMenu

        // -----------------------------------------------------------------
        // View menu — windows / panels you can open. All of these are
        // observability surfaces over the same underlying detector +
        // event-bus state.
        // -----------------------------------------------------------------
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(menuItem("Status Panel", action: #selector(openStatus(_:)), key: "i", mods: [.command]))
        viewMenu.addItem(menuItem("Detection History", action: #selector(openHistory(_:)), key: "h", mods: [.command, .shift]))
        viewMenu.addItem(menuItem("Log Stream", action: #selector(openLogStream(_:)), key: "l", mods: [.command]))
        viewItem.submenu = viewMenu

        // -----------------------------------------------------------------
        // Camera menu — devices listed directly (no nested submenu), then
        // Refresh, then Privacy. Privacy lives here because its primary
        // effect is gating what the camera-facing detectors do.
        // -----------------------------------------------------------------
        let cameraItem = NSMenuItem()
        mainMenu.addItem(cameraItem)
        let cameraMenu = NSMenu(title: "Camera")
        cameraMenu.delegate = self
        // The dynamic device list is rebuilt by menuNeedsUpdate(_:) each
        // time the menu opens. We retain a reference so the rebuild and
        // the privacy/refresh items stay distinct.
        cameraDevicesSubmenu = cameraMenu
        cameraItem.submenu = cameraMenu

        // -----------------------------------------------------------------
        // Faces menu — enrollment of known people.
        // -----------------------------------------------------------------
        let facesItem = NSMenuItem()
        mainMenu.addItem(facesItem)
        let facesMenu = NSMenu(title: "Faces")
        facesMenu.addItem(menuItem("Enroll Face…", action: #selector(enrollFace(_:)), key: "e", mods: [.command]))
        facesMenu.addItem(menuItem("Forget Face…", action: #selector(forgetFace(_:)), key: "e", mods: [.command, .shift]))
        facesItem.submenu = facesMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    /// Small helper to keep the menu-building above readable.
    @MainActor
    private func menuItem(_ title: String,
                          action: Selector?,
                          key: String,
                          mods: NSEvent.ModifierFlags,
                          target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target ?? self
        return item
    }

    // MARK: - Camera menu (dynamic)

    @MainActor
    @objc func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === cameraDevicesSubmenu else { return }
        rebuildCameraDevicesMenu(menu)
    }

    @MainActor
    private func rebuildCameraDevicesMenu(_ menu: NSMenu) {
        // Rebuilds the entire Camera menu in place: device list (flat),
        // separator, Refresh List, separator, Privacy Mode toggle.
        menu.removeAllItems()

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices

        if devices.isEmpty {
            let empty = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let activeID = windowController?.activeCameraUniqueID
            for device in devices {
                let item = NSMenuItem(
                    title: device.localizedName,
                    action: #selector(selectCameraDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device
                if device.uniqueID == activeID {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: "Refresh List",
            action: #selector(refreshCameraList(_:)),
            keyEquivalent: ""
        )
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let privacyTitle = Theme.Performance.faceRecognitionDisabled
            ? "Privacy Mode: ON"
            : "Privacy Mode: OFF"
        let privacy = NSMenuItem(
            title: privacyTitle,
            action: #selector(togglePrivacyMode(_:)),
            keyEquivalent: "p"
        )
        privacy.keyEquivalentModifierMask = [.command, .shift]
        privacy.target = self
        menu.addItem(privacy)
        privacyMenuItem = privacy
    }

    @MainActor
    @objc private func refreshCameraList(_ sender: Any?) {
        guard let menu = cameraDevicesSubmenu else { return }
        rebuildCameraDevicesMenu(menu)
    }

    @MainActor
    @objc private func selectCameraDevice(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let device = item.representedObject as? AVCaptureDevice else { return }
        windowController?.switchCamera(to: device)
    }

    // MARK: - Snapshot

    @MainActor
    @objc private func saveSnapshot(_ sender: Any?) {
        windowController?.saveSnapshotToDesktop()
    }

    // MARK: - Settings

    @MainActor
    @objc private func openSettings(_ sender: Any?) {
        if settingsController == nil {
            // The detector is owned by the main window controller. We pass a
            // closure that the Diagnostics section polls at 2 Hz; returning
            // nil hides the Diagnostics block (e.g. before the window exists
            // or if the detector hasn't started reporting timings yet).
            let provider: @MainActor () -> DiagnosticsTimingSnapshot? = { [weak self] in
                self?.currentDetectorTiming()
            }
            settingsController = SettingsWindowController(timingProvider: provider)
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reads `detector.lastStageTiming` reflectively via KVC. The detector is
    /// owned by Agent A; if they haven't added the property yet, KVC returns
    /// nil and the Diagnostics block stays hidden. This keeps the App layer
    /// from build-coupling to a Process-layer symbol that may not exist.
    @MainActor
    private func currentDetectorTiming() -> DiagnosticsTimingSnapshot? {
        guard let detector = windowController?.detector else { return nil }
        // Use Mirror to look for a `lastStageTiming` member without naming
        // the type. If it isn't present, return nil; otherwise project its
        // children into our snapshot struct by label.
        let mirror = Mirror(reflecting: detector)
        guard let raw = mirror.descendant("lastStageTiming") else { return nil }
        let inner = Mirror(reflecting: raw)
        var snap = DiagnosticsTimingSnapshot.zero
        for child in inner.children {
            guard let label = child.label else { continue }
            let value = (child.value as? Double) ?? Double((child.value as? Float) ?? 0)
            switch label {
            case "visionBundleMs": snap.visionBundleMs = value
            case "featurePrintMs": snap.featurePrintMs = value
            case "trackerMs":      snap.trackerMs = value
            case "totalMs":        snap.totalMs = value
            default: break
            }
        }
        return snap
    }

    @MainActor
    @objc private func openLogStream(_ sender: Any?) {
        if logController == nil {
            logController = LogStreamWindowController()
        }
        logController?.showWindow(nil)
        logController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc private func openHistory(_ sender: Any?) {
        if historyController == nil {
            historyController = HistoryWindowController()
        }
        historyController?.showWindow(nil)
        historyController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc private func openStatus(_ sender: Any?) {
        if statusController == nil {
            statusController = StatusWindowController(detectorAccess: { [weak self] in
                self?.buildDetectorSnapshot()
            })
        }
        statusController?.showWindow(nil)
        statusController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func buildDetectorSnapshot() -> DetectorSnapshot? {
        guard let wc = windowController else { return nil }
        let det = wc.detector
        let detections = det.currentDetections()

        // Partition into face vs. object entries. A detection's label is a
        // recognized name when it's an enrolled face — those labels are
        // uppercased and don't appear in the COCO/OIV7 class set. Treat
        // anything explicitly named "FACE" or matching an enrolled name as
        // a face entry; everything else is an object.
        let enrolledUpper = Set(det.faceRegistry.enrolledNames().map { $0.uppercased() })
        var faces: [DetectorSnapshot.FaceEntry] = []
        var objects: [DetectorSnapshot.ObjectEntry] = []
        for d in detections {
            if d.label == "FACE" || enrolledUpper.contains(d.label) {
                faces.append(.init(name: d.label.lowercased(), distance: nil))
            } else {
                let rgba = ColorHash.colorFor(trackId: d.trackId)
                objects.append(.init(
                    label: d.label,
                    confidence: d.confidence,
                    color: Color(red: Double(rgba.x),
                                 green: Double(rgba.y),
                                 blue: Double(rgba.z))
                ))
            }
        }
        // Sort objects by confidence descending so the most-confident detections lead.
        objects.sort { $0.confidence > $1.confidence }

        return DetectorSnapshot(
            fps: wc.renderer.smoothedFPSForReadout,
            lastInferenceMs: det.lastInferenceMs,
            detectMode: det.lastDetectMode.rawValue,
            objects: objects,
            faces: faces
        )
    }

    // MARK: - Privacy Mode

    @MainActor
    @objc private func togglePrivacyMode(_ sender: Any?) {
        let newValue = !Theme.Performance.faceRecognitionDisabled
        Theme.Performance.faceRecognitionDisabled = newValue
        Theme.Performance.greeterMuted = newValue
        TunableSettings.shared.greeterMuted = newValue
        privacyMenuItem?.title = newValue ? "Privacy Mode: ON" : "Privacy Mode: OFF"
        LogStream.shared.log(
            "privacy mode \(newValue ? "enabled" : "disabled")",
            level: .info,
            source: .app
        )
    }

    // MARK: - Recording

    @MainActor
    @objc private func toggleRecording(_ sender: Any?) {
        if let rec = recorder, rec.isRecording {
            stopRecordingFlow(rec)
        } else {
            startRecordingFlow()
        }
    }

    @MainActor
    private func startRecordingFlow() {
        guard let renderer = windowController?.renderer,
              let device = MTLCreateSystemDefaultDevice(),
              let rec = Recorder(device: device) else {
            showRecordingResult(url: nil, started: false)
            return
        }
        // Use the renderer's drawable size if available, otherwise the main
        // screen. Recorder needs an integer width/height to allocate the
        // AVAssetWriterInput at the right resolution.
        let size = currentRecordingSize()
        let started = rec.startRecording(width: size.width, height: size.height)
        guard started else {
            recorder = nil
            showRecordingResult(url: nil, started: false)
            return
        }
        recorder = rec
        renderer.frameTap = { [weak rec] texture, time in
            rec?.writeFrame(texture: texture, time: time)
        }
        recordMenuItem?.title = "Stop Recording"
        LogStream.shared.log("recording started (\(size.width)x\(size.height))", level: .info, source: .app)
    }

    @MainActor
    private func stopRecordingFlow(_ rec: Recorder) {
        // Drop the frame tap immediately so no more frames queue up while the
        // writer is finishing. The recorder owns the in-flight pixel buffer
        // until its completion fires.
        windowController?.renderer.frameTap = nil
        rec.stopRecording { [weak self] url in
            Task { @MainActor in
                guard let self else { return }
                self.recorder = nil
                self.recordMenuItem?.title = "Start Recording"
                self.showRecordingResult(url: url, started: true)
            }
        }
    }

    @MainActor
    private func currentRecordingSize() -> (width: Int, height: Int) {
        if let view = windowController?.window?.contentView as? NSView {
            let scale = view.window?.backingScaleFactor ?? 2.0
            let bounds = view.bounds
            let w = Int((bounds.width * scale).rounded())
            let h = Int((bounds.height * scale).rounded())
            if w > 0 && h > 0 { return (w, h) }
        }
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        return (Int(frame.width), Int(frame.height))
    }

    @MainActor
    private func showRecordingResult(url: URL?, started: Bool) {
        let alert = NSAlert()
        if let url {
            alert.messageText = "Recording saved"
            alert.informativeText = "Saved to \(url.path)"
        } else if started {
            alert.messageText = "Recording failed"
            alert.informativeText = "The recorder did not produce a file."
            alert.alertStyle = .warning
        } else {
            alert.messageText = "Recording failed to start"
            alert.informativeText = "The recorder could not be initialized."
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    // MARK: - Face enrollment

    @MainActor
    @objc private func enrollFace(_ sender: Any?) {
        guard let detector = windowController?.detector else { return }

        let alert = NSAlert()
        alert.messageText = "Enroll Face"
        alert.informativeText = "Aim the camera at the person you want VisionPOC to remember, type their name, and press Start. The next few frames containing a face will be captured."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "Name (e.g. James)"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // Capture inside the detector queue: feed prints straight into the
        // registry (which is thread-safe) and only ship the count back to
        // MainActor for the confirmation dialog. This avoids sending the
        // non-Sendable VNFeaturePrintObservation array across actor isolation.
        let registry = detector.faceRegistry
        detector.captureFeaturePrints(count: 5) { prints in
            registry.enroll(name: name, prints: prints)
            let count = prints.count
            Task { @MainActor in
                AppDelegate.showEnrollmentResult(name: name, count: count)
            }
        }
    }

    @MainActor
    private static func showEnrollmentResult(name: String, count: Int) {
        let alert = NSAlert()
        if count == 0 {
            alert.messageText = "Enrollment cancelled"
            alert.informativeText = "No face was captured."
        } else {
            alert.messageText = "Enrolled \(name)"
            alert.informativeText = "Saved \(count) face print\(count == 1 ? "" : "s"). The HUD will start labeling \(name) on the next detection cycle."
        }
        alert.runModal()
    }

    @MainActor
    @objc private func forgetFace(_ sender: Any?) {
        guard let detector = windowController?.detector else { return }

        let names = detector.faceRegistry.enrolledNames()
        guard !names.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No enrolled faces"
            alert.informativeText = "There are no faces in the registry yet. Use Enroll Face… first."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Forget Face"
        alert.informativeText = "Pick a name to remove from the registry. This deletes the stored face prints from disk."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: names)
        alert.accessoryView = popup

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn,
              let chosen = popup.titleOfSelectedItem else { return }

        detector.faceRegistry.forget(name: chosen)
    }

    private static func registerBundledFonts() {
        let names = ["ShareTechMono-Regular", "Orbitron-Bold"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                if let err = error?.takeRetainedValue() {
                    NSLog("Font registration failed for \(name): \(err)")
                }
            }
        }
    }
}

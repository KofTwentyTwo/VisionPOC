import AppKit
import AVFoundation
import CoreText
import Vision

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @unchecked Sendable {
    private var windowController: MainWindowController?
    @MainActor private var settingsController: SettingsWindowController?
    @MainActor private var logController: LogStreamWindowController?
    @MainActor private var cameraDevicesSubmenu: NSMenu?

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

        // Application menu (Settings, Quit).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        appMenu.addItem(settings)

        let logStream = NSMenuItem(
            title: "Log Stream…",
            action: #selector(openLogStream(_:)),
            keyEquivalent: "l"
        )
        logStream.keyEquivalentModifierMask = [.command]
        logStream.target = self
        appMenu.addItem(logStream)

        appMenu.addItem(.separator())

        let snapshot = NSMenuItem(
            title: "Save Snapshot",
            action: #selector(saveSnapshot(_:)),
            keyEquivalent: "s"
        )
        snapshot.keyEquivalentModifierMask = [.command]
        snapshot.target = self
        appMenu.addItem(snapshot)

        appMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu

        // Faces menu — enrollment + forgetting.
        let facesItem = NSMenuItem()
        mainMenu.addItem(facesItem)
        let facesMenu = NSMenu(title: "Faces")

        let enrollItem = NSMenuItem(
            title: "Enroll Face…",
            action: #selector(enrollFace(_:)),
            keyEquivalent: "e"
        )
        enrollItem.keyEquivalentModifierMask = [.command]
        enrollItem.target = self
        facesMenu.addItem(enrollItem)

        let forgetItem = NSMenuItem(
            title: "Forget Face…",
            action: #selector(forgetFace(_:)),
            keyEquivalent: "e"
        )
        forgetItem.keyEquivalentModifierMask = [.command, .shift]
        forgetItem.target = self
        facesMenu.addItem(forgetItem)

        facesItem.submenu = facesMenu

        // Camera menu — device picker (dynamic) + manual refresh.
        let cameraItem = NSMenuItem()
        mainMenu.addItem(cameraItem)
        let cameraMenu = NSMenu(title: "Camera")

        let devicesItem = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        let devicesSubmenu = NSMenu(title: "Devices")
        devicesSubmenu.delegate = self
        devicesItem.submenu = devicesSubmenu
        cameraDevicesSubmenu = devicesSubmenu
        cameraMenu.addItem(devicesItem)

        let refreshItem = NSMenuItem(
            title: "Refresh List",
            action: #selector(refreshCameraList(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        cameraMenu.addItem(refreshItem)

        cameraItem.submenu = cameraMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Camera menu (dynamic)

    @MainActor
    @objc func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === cameraDevicesSubmenu else { return }
        rebuildCameraDevicesMenu(menu)
    }

    @MainActor
    private func rebuildCameraDevicesMenu(_ menu: NSMenu) {
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
            return
        }

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
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

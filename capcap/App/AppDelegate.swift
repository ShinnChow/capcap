import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var overlayController: OverlayWindowController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showStartupDialog()
    }

    private func showStartupDialog() {
        let settingsController = SettingsWindowController.shared

        settingsController.onMenuBarToggle = { [weak self] visible in
            self?.statusBarController?.setMenuBarVisible(visible)
        }

        settingsController.onLaunch = { [weak self] in
            self?.initializeApp()
        }

        settingsController.showAsStartupDialog()
    }

    private func initializeApp() {
        ImageEditLauncher.clearTempDir()

        statusBarController = StatusBarController(
            onTakeScreenshot: { [weak self] in self?.handleTrigger() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        statusBarController.setMenuBarVisible(Defaults.showMenuBar)

        keyMonitor = KeyMonitor { [weak self] in
            self?.handleTrigger()
        }

        NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHotkeyState()
        }
        applyHotkeyState()
    }

    private func applyHotkeyState() {
        if HotkeyManager.shared.isRecording {
            HotkeyManager.shared.unregister()
            keyMonitor?.isEnabled = false
            return
        }
        if Defaults.hasCustomScreenshotHotkey {
            HotkeyManager.shared.register { [weak self] in
                self?.handleTrigger()
            }
            keyMonitor?.isEnabled = false
        } else {
            HotkeyManager.shared.unregister()
            keyMonitor?.isEnabled = true
        }
    }

    func handleTrigger() {
        guard overlayController == nil else { return }

        // Image-edit shortcut: if Finder has exactly one image selected, edit
        // that file directly. Any failure (no permission, load error, no
        // selection) falls through to the normal screenshot flow.
        if let url = FinderSelection.currentImageFileURL(),
           let controller = ImageEditLauncher.launch(
               sourceURL: url,
               onComplete: { [weak self] finalImage in
                   self?.handleEditCompletion(finalImage)
               }
           )
        {
            overlayController = controller
            return
        }

        startCapture()
    }

    func startCapture() {
        guard overlayController == nil else { return }
        overlayController = OverlayWindowController { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }
        overlayController?.activate()
    }

    private func handleEditCompletion(_ finalImage: NSImage?) {
        if let finalImage = finalImage {
            ClipboardManager.copyToClipboard(image: finalImage)
            HistoryManager.shared.add(image: finalImage)
            ToastWindow.show()
        }
        overlayController = nil
    }

    private func openSettings() {
        SettingsWindowController.shared.showAsSettings()
    }
}

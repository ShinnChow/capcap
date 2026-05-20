import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var overlayController: OverlayWindowController?
    private var countdownActive = false
    private var appInitialized = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showStartupDialog()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if appInitialized {
            openSettings()
        } else {
            SettingsWindowController.shared.showAsStartupDialog()
        }
        return false
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
        guard !appInitialized else { return }
        appInitialized = true

        ImageEditLauncher.clearTempDir()

        statusBarController = StatusBarController(
            onTakeScreenshot: { [weak self] in self?.handleTrigger() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        statusBarController.setMenuBarVisible(Defaults.showMenuBar)

        keyMonitor = KeyMonitor(
            onTrigger: { [weak self] in self?.handleDoubleTapCommand() },
            onCountdownTrigger: { [weak self] in self?.handleCountdownTrigger() }
        )

        NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHotkeyState()
        }
        applyHotkeyState()

        // Quietly look for a newer release (throttled to once per 24h). A hit
        // surfaces only in the menu bar item and the About pane — no popup.
        UpdateChecker.shared.checkOnLaunchIfDue()
    }

    private func applyHotkeyState() {
        if HotkeyManager.shared.isRecording {
            HotkeyManager.shared.unregister()
            HotkeyManager.shared.unregisterCountdown()
            HotkeyManager.shared.unregisterPin()
            keyMonitor?.isEnabled = false
            return
        }
        keyMonitor?.isEnabled = true
        if Defaults.hasCustomScreenshotHotkey {
            HotkeyManager.shared.register { [weak self] in
                self?.handleTrigger()
            }
            HotkeyManager.shared.registerCountdown { [weak self] in
                self?.handleCountdownTrigger()
            }
        } else {
            HotkeyManager.shared.unregister()
            HotkeyManager.shared.unregisterCountdown()
        }

        // Double-tap ⌘ does two jobs: it's the default screenshot trigger
        // when no custom screenshot hotkey is set, and the default
        // copy-to-clipboard trigger while an overlay is up (when no custom
        // clipboard hotkey is set). Keep it live whenever either path needs it.
        let needsDoubleTap = !Defaults.hasCustomScreenshotHotkey
            || (overlayController != nil && !Defaults.hasCustomClipboardHotkey)
        keyMonitor?.isRegularDoubleTapEnabled = needsDoubleTap

        // The pin hotkey is independent of the screenshot hotkey.
        if Defaults.hasCustomPinHotkey {
            HotkeyManager.shared.registerPin { [weak self] in
                self?.handlePinTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterPin()
        }
    }

    /// KeyMonitor entry point for plain double-tap ⌘. While an overlay is
    /// active this is the default copy-to-clipboard hotkey; otherwise it falls
    /// through to the regular screenshot trigger.
    private func handleDoubleTapCommand() {
        if let overlay = overlayController {
            if !Defaults.hasCustomClipboardHotkey {
                overlay.confirmFromKeyboard()
            }
            return
        }
        handleTrigger()
    }

    func handleTrigger() {
        guard overlayController == nil else { return }

        // Image-edit shortcut: edit an image directly instead of capturing.
        // Any failure (no permission, load error, nothing there) falls through
        // to the next source, and finally to the normal screenshot flow.
        if let controller = launchImageEdit() {
            overlayController = controller
            applyHotkeyState()
            return
        }

        startCapture()
    }

    /// Tries the image-edit sources in priority order: a single image selected
    /// in Finder first, then an image already on the clipboard. Returns nil
    /// when neither has an editable image.
    private func launchImageEdit() -> OverlayWindowController? {
        let onComplete: (NSImage?) -> Void = { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }
        // X in the preset editor abandons it and starts the normal capture.
        let onSwitchToCapture: () -> Void = { [weak self] in
            self?.overlayController = nil
            self?.startCapture()
        }

        if let url = FinderSelection.currentImageFileURL(),
           let controller = ImageEditLauncher.launch(
               sourceURL: url,
               onComplete: onComplete,
               onSwitchToCapture: onSwitchToCapture
           ) {
            return controller
        }

        if let image = ClipboardImageSource.currentImage(),
           let controller = ImageEditLauncher.launch(
               clipboardImage: image,
               onComplete: onComplete,
               onSwitchToCapture: onSwitchToCapture
           ) {
            return controller
        }

        return nil
    }

    /// Countdown-triggered capture. Skips the Finder image-edit shortcut on
    /// purpose — the user explicitly asked for a delayed screen capture.
    func handleCountdownTrigger() {
        guard overlayController == nil, !countdownActive else { return }
        countdownActive = true
        CountdownWindow.start(
            seconds: Defaults.countdownSeconds,
            onFinish: { [weak self] in
                self?.countdownActive = false
                self?.startCapture()
            },
            onCancel: { [weak self] in
                self?.countdownActive = false
            }
        )
    }

    /// Pin-hotkey trigger: pin the Finder selection or clipboard image onto the
    /// screen. Skipped while a capture overlay is up.
    func handlePinTrigger() {
        guard overlayController == nil else { return }
        PinLauncher.pinFromSourcesIfAvailable()
    }

    func startCapture() {
        guard overlayController == nil else { return }
        overlayController = OverlayWindowController { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }
        overlayController?.activate()
        applyHotkeyState()
    }

    private func handleEditCompletion(_ finalImage: NSImage?) {
        if let finalImage = finalImage {
            ClipboardManager.copyToClipboard(image: finalImage)
            HistoryManager.shared.add(image: finalImage)
            ToastWindow.show()
        }
        overlayController = nil
        applyHotkeyState()
    }

    private func openSettings() {
        SettingsWindowController.shared.showAsSettings()
    }
}

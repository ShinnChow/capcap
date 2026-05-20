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
            HotkeyManager.shared.unregisterSelectedImagePin()
            HotkeyManager.shared.unregisterClipboardImagePin()
            HotkeyManager.shared.unregisterSelectedImageEdit()
            HotkeyManager.shared.unregisterClipboardImageEdit()
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

        // The pin hotkeys are independent of the screenshot hotkey.
        if Defaults.hasCustomSelectedImagePinHotkey {
            HotkeyManager.shared.registerSelectedImagePin { [weak self] in
                self?.handleSelectedImagePinTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterSelectedImagePin()
        }

        if Defaults.hasCustomClipboardImagePinHotkey {
            HotkeyManager.shared.registerClipboardImagePin { [weak self] in
                self?.handleClipboardImagePinTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterClipboardImagePin()
        }

        if Defaults.hasCustomSelectedImageEditHotkey {
            HotkeyManager.shared.registerSelectedImageEdit { [weak self] in
                self?.handleSelectedImageEditTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterSelectedImageEdit()
        }

        if Defaults.hasCustomClipboardImageEditHotkey {
            HotkeyManager.shared.registerClipboardImageEdit { [weak self] in
                self?.handleClipboardImageEditTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterClipboardImageEdit()
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
        startCapture()
    }

    /// Opens the single image currently selected in Finder directly in the
    /// editor. Returns nil when Finder has no exactly-one editable image.
    private func launchSelectedImageEdit() -> OverlayWindowController? {
        let onComplete: (NSImage?) -> Void = { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }

        if let url = FinderSelection.currentImageFileURL(),
           let controller = ImageEditLauncher.launch(
               sourceURL: url,
               onComplete: onComplete
           ) {
            return controller
        }

        return nil
    }

    /// Opens the current clipboard image directly in the editor. Returns nil
    /// when the clipboard has no editable image.
    private func launchClipboardImageEdit() -> OverlayWindowController? {
        let onComplete: (NSImage?) -> Void = { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }

        if let image = ClipboardImageSource.currentImage(),
           let controller = ImageEditLauncher.launch(
               clipboardImage: image,
               onComplete: onComplete
           ) {
            return controller
        }

        return nil
    }

    /// Countdown-triggered capture. It never checks image-edit sources; the
    /// user explicitly asked for a delayed screen capture.
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

    /// Pin-hotkey trigger: pin Finder selection onto the screen. Skipped while
    /// a capture overlay is up.
    func handleSelectedImagePinTrigger() {
        guard overlayController == nil else { return }
        PinLauncher.pinSelectedImagesIfAvailable()
    }

    /// Pin-hotkey trigger: pin the clipboard image onto the screen. Skipped
    /// while a capture overlay is up.
    func handleClipboardImagePinTrigger() {
        guard overlayController == nil else { return }
        PinLauncher.pinClipboardImageIfAvailable()
    }

    func handleSelectedImageEditTrigger() {
        guard overlayController == nil, !countdownActive else { return }
        guard let controller = launchSelectedImageEdit() else {
            ToastWindow.show(message: L10n.selectedImageEditNoImage)
            return
        }
        overlayController = controller
        applyHotkeyState()
    }

    func handleClipboardImageEditTrigger() {
        guard overlayController == nil, !countdownActive else { return }
        guard let controller = launchClipboardImageEdit() else {
            ToastWindow.show(message: L10n.clipboardImageEditNoImage)
            return
        }
        overlayController = controller
        applyHotkeyState()
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

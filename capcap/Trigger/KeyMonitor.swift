import AppKit

class KeyMonitor {
    /// Master switch. When false, neither trigger fires (used during shortcut recording).
    var isEnabled: Bool = true {
        didSet {
            if !isEnabled { resetSequence() }
        }
    }

    /// Plain double-tap ⌘ → regular screenshot. Disabled when a custom hotkey is registered.
    var isRegularDoubleTapEnabled: Bool = true {
        didSet { if !isRegularDoubleTapEnabled { resetSequence() } }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownMonitor: Any?
    private var lastCommandPressTime: TimeInterval = 0
    private var lastCommandPressOption: Bool = false
    private var commandIsDown = false
    private var otherKeyPressed = false
    private let onTrigger: () -> Void
    private let onCountdownTrigger: () -> Void

    init(onTrigger: @escaping () -> Void,
         onCountdownTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        self.onCountdownTrigger = onCountdownTrigger
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
    }

    private func stopMonitoring() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = keyDownMonitor { NSEvent.removeMonitor(m) }
    }

    private func resetSequence() {
        lastCommandPressTime = 0
        commandIsDown = false
        otherKeyPressed = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isEnabled else { return }
        let cmd = event.modifierFlags.contains(.command)
        let opt = event.modifierFlags.contains(.option)
        // Shift / Control invalidate any in-flight double-tap sequence so the
        // user can't accidentally fire either trigger from a stray combo.
        let hasDisruptive = event.modifierFlags.contains(.shift)
            || event.modifierFlags.contains(.control)

        if hasDisruptive {
            otherKeyPressed = true
            commandIsDown = cmd
            return
        }

        if cmd && !commandIsDown {
            let now = ProcessInfo.processInfo.systemUptime
            let withinWindow = (now - lastCommandPressTime) < Defaults.doubleTapInterval
            // Both presses must share the same Option state — a sequence that
            // mixes ⌘ then ⌥⌘ is treated as a fresh first press, not a double-tap.
            let isDoubleTap = !otherKeyPressed
                && withinWindow
                && lastCommandPressOption == opt

            if isDoubleTap {
                if opt {
                    DispatchQueue.main.async { [weak self] in self?.onCountdownTrigger() }
                } else if isRegularDoubleTapEnabled {
                    DispatchQueue.main.async { [weak self] in self?.onTrigger() }
                }
                lastCommandPressTime = 0
            } else {
                lastCommandPressTime = now
                lastCommandPressOption = opt
            }
            otherKeyPressed = false
        }

        commandIsDown = cmd
    }
}

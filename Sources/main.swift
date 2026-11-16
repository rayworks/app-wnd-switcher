import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Accessibility helpers

private func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

private func isAccessibilityTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

// MARK: - Window cycling

final class WindowCycler {
    /// Cycle order remembered per app, so repeated presses walk through every
    /// window instead of bouncing between the two most recent ones.
    private var order: [pid_t: [AXUIElement]] = [:]

    func cycle(forward: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        let current = switchableWindows(of: axApp)
        guard current.count > 1 else { return }

        // Keep the remembered order while the set of windows is unchanged;
        // otherwise start over from the current front-to-back order.
        var list = order[pid] ?? []
        let sameSet = list.count == current.count
            && list.allSatisfy { known in current.contains { CFEqual($0, known) } }
        if !sameSet {
            list = current
            order[pid] = list
        }

        let focused: AXUIElement? = axValue(axApp, kAXFocusedWindowAttribute)
            ?? axValue(axApp, kAXMainWindowAttribute)
        let index = focused.flatMap { f in list.firstIndex { CFEqual($0, f) } } ?? 0
        let next = list[(index + (forward ? 1 : list.count - 1)) % list.count]

        AXUIElementPerformAction(next, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(next, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, next)

        // Forget apps that have quit.
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        order = order.filter { running.contains($0.key) }
    }

    private func switchableWindows(of axApp: AXUIElement) -> [AXUIElement] {
        let all: [AXUIElement] = axValue(axApp, kAXWindowsAttribute) ?? []
        let visible = all.filter { (axValue($0, kAXMinimizedAttribute) as Bool?) != true }
        let standard = visible.filter {
            let subrole: String? = axValue($0, kAXSubroleAttribute)
            return subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String)
        }
        return standard.isEmpty ? visible : standard
    }
}

// MARK: - Global hotkey (Carbon; needs no extra permission)

final class HotKeys {
    static var handler: ((UInt32) -> Void)?
    private var refs: [EventHotKeyRef] = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKeys.handler?(id.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x574E_4453) /* 'WNDS' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
        return status == noErr
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let cycler = WindowCycler()
    private let hotKeys = HotKeys()
    private var statusItem: NSStatusItem!
    private let accessItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var hotKeysOK = false

    /// On/off switch, remembered across launches (defaults to on).
    private var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeys.handler = { [weak self] id in
            guard isAccessibilityTrusted(prompt: true) else { return }
            self?.cycler.cycle(forward: id == 1)
        }
        setUpMenu()
        applyEnabled()
        _ = isAccessibilityTrusted(prompt: true)
    }

    /// Registers or releases the hotkeys to match the switch. While off, ⌥`
    /// goes back to its normal behaviour in every app.
    private func applyEnabled() {
        hotKeys.unregisterAll()
        if isEnabled {
            let next = hotKeys.register(id: 1, keyCode: kVK_ANSI_Grave, modifiers: optionKey)
            let prev = hotKeys.register(id: 2, keyCode: kVK_ANSI_Grave, modifiers: optionKey | shiftKey)
            hotKeysOK = next
            NSLog("WndSwitcher: hotkeys registered — ⌥`: %@, ⇧⌥`: %@", next ? "ok" : "FAILED", prev ? "ok" : "FAILED")
        } else {
            NSLog("WndSwitcher: disabled, hotkeys released")
        }
        enabledItem.state = isEnabled ? .on : .off
        hintItem.title = !isEnabled ? "Switching is off"
            : hotKeysOK ? "⌥`  Next window    ⇧⌥`  Previous window"
            : "⌥` is taken by another app"
        statusItem.button?.appearsDisabled = !isEnabled
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        applyEnabled()
    }

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                           accessibilityDescription: "WndSwitcher")

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "WndSwitcher \(version) (\(build))", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(hintItem)
        menu.addItem(.separator())
        accessItem.target = self
        menu.addItem(accessItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WndSwitcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessItem.title = isAccessibilityTrusted(prompt: false)
            ? "Accessibility: Granted"
            : "Accessibility: Not Granted — Open Settings…"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("WndSwitcher: launch-at-login change failed: %@", error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

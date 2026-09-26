// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox
import LinearViewsKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = LinearStore()
    private var statusItem: NSStatusItem!
    private var panel: DropPanel!
    private var outsideClickMonitor: Any?
    private var settingsWindow: NSWindow?
    static let togglePanelCommand = "togglePanel"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = Bundle.main.image(forResource: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
            image?.size = NSSize(width: 15, height: 15)
            image?.isTemplate = true
            image?.accessibilityDescription = "Linear Views"
            button.image = image
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let actions = PanelActions(openSettings: { [weak self] in self?.openSettings(nil) },
                                   close: { [weak self] in self?.closePanel() })
        panel = DropPanel(rootView: PanelView(store: store, actions: actions))
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        HotKeyCenter.shared.register(Self.togglePanelCommand) { [weak self] in self?.togglePanel() }
        updateTooltip()

        if store.apiKey.isEmpty {
            openSettings(nil)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePanel()
    }

    private func updateTooltip() {
        statusItem.button?.toolTip = store.current?.name ?? "Linear Views"
    }

    // MARK: Panel

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible && NSApp.isActive {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        // Drop down from the icon, centred on it but kept inside the screen.
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? iconFrame
        let size = panel.frame.size
        let x = min(max(iconFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: iconFrame.minY - 6 - size.height))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NotificationCenter.default.post(name: .panelDidShow, object: nil)
        store.refreshIfStale()
        updateTooltip()

        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            }
        }
    }

    private func closePanel() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
        updateTooltip()
    }

    /// ⌘R refreshes and ⌘, opens Settings from anywhere in the panel.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": store.refresh()
        case ",": openSettings(nil)
        case "w": closePanel()
        default: return false
        }
        return true
    }

    // MARK: Menus

    /// Right-click: switch views without opening the panel first, as the
    /// Raycast menu bar command did.
    private func showContextMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Views", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for view in store.usableViews {
            let item = NSMenuItem(title: view.name, action: #selector(showView(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = view.id
            item.state = view.id == store.current?.id ? .on : .off
            menu.addItem(item)
        }
        for view in store.views where view.problem != nil && !(view.name.isEmpty && view.url.isEmpty) {
            let item = NSMenuItem(title: "Check \(view.name.isEmpty ? "a view" : view.name): \(view.problem ?? "")",
                                  action: #selector(openSettings(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Configure Views…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Linear Views", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showView(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let view = store.usableViews.first(where: { $0.id == id }) else { return }
        store.select(view)
        showPanel()
    }

    @objc func openSettings(_ sender: Any?) {
        closePanel()
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow(store: store)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Accessory apps have no visible menu bar, but the main menu still routes
    /// key equivalents; without it ⌘C, ⌘V and ⌘A don't work in text fields.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Linear Views", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}

/// A borderless, transparent panel that drops down from the menu bar icon;
/// its shadow follows the glass view's rounded alpha.
final class DropPanel: NSPanel {
    var onCancel: () -> Void = {}
    var onKey: (NSEvent) -> Bool = { _ in false }

    init<Content: View>(rootView: Content) {
        let size = NSSize(width: Metrics.panelWidth, height: Metrics.panelHeight)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        contentView = NSHostingView(rootView: rootView)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey(event) { return }
        super.sendEvent(event)
    }

    /// Esc that nothing inside handled: on the list, it closes the panel.
    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

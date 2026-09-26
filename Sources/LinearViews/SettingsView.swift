// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import LinearViewsKit
import ServiceManagement
import SwiftUI

/// A preferences window with toolbar tabs, like the system's own apps.
@MainActor
func makeSettingsWindow(store: LinearStore) -> NSWindow {
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.addTabViewItem(settingsTab("Views", symbol: "list.bullet.rectangle", ViewsSettingsView(store: store)))
    tabs.addTabViewItem(settingsTab("General", symbol: "gearshape", GeneralSettingsView()))

    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.center()
    return window
}

private func settingsTab<Content: View>(_ label: String, symbol: String, _ view: Content) -> NSTabViewItem {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = .preferredContentSize
    controller.title = label
    let item = NSTabViewItem(viewController: controller)
    item.label = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    return item
}

// MARK: - Views

private struct ViewsSettingsView: View {
    @ObservedObject var store: LinearStore
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section {
                SecureField("Linear API Key", text: $apiKey)
                    .onSubmit { store.apiKey = apiKey }
                    .onChange(of: apiKey) { _, value in
                        if value != store.apiKey { store.apiKey = value }
                    }
            } footer: {
                Text("A personal key from Linear → Settings → Security & access, with read and write access to the teams in your views (write is used only for edits from the issue details). Kept in your login keychain and sent only to api.linear.app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach($store.views) { $view in
                    ViewRow(view: $view, isDefault: store.defaultViewID == view.id,
                            makeDefault: { store.defaultViewID = view.id },
                            remove: { store.views.removeAll { $0.id == view.id } })
                }
                .onMove { store.views.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    store.views.append(SavedView(name: "", url: ""))
                } label: {
                    Label("Add View", systemImage: "plus")
                }
            } header: {
                Text("Views")
            } footer: {
                Text("Paste a saved Linear custom view's URL, e.g. https://linear.app/team/view/todo-41428a79d10e. Linear applies the view's saved filters; URLs with temporary filters are rejected, so save those filters in Linear first. The starred view is shown until you pick another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .onAppear { apiKey = store.apiKey }
    }
}

private struct ViewRow: View {
    @Binding var view: SavedView
    let isDefault: Bool
    let makeDefault: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: makeDefault) {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .foregroundStyle(isDefault ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isDefault ? "Default view" : "Make Default")
                TextField("Name", text: $view.name, prompt: Text("Name"))
                    .labelsHidden()
                    .frame(width: 130)
                TextField("URL", text: $view.url, prompt: Text("https://linear.app/…/view/…"))
                    .labelsHidden()
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove View")
            }
            if let problem = view.problem, !(view.name.isEmpty && view.url.isEmpty) {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 26)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Linear Views at login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Show or hide the panel") {
                    ShortcutRecorder(AppDelegate.togglePanelCommand)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Works in every app. Right-click the menu bar icon to switch views.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 260)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

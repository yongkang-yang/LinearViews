// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import LinearViewsKit
import SwiftUI

/// What the panel's buttons reach outside it.
struct PanelActions {
    var openSettings: () -> Void
    var close: () -> Void
}

/// The drop-down panel: the current view's issues, and an issue's details.
struct PanelView: View {
    @ObservedObject var store: LinearStore
    let actions: PanelActions
    @State private var search = ""
    @State private var selection: String?
    @State private var detail: Issue?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            list
                .opacity(detail == nil ? 1 : 0)
                .allowsHitTesting(detail == nil)
            if let detail {
                IssueDetailView(store: store, issue: detail, back: { self.detail = nil; searchFocused = true })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: detail?.id)
        .frame(width: Metrics.panelWidth, height: Metrics.panelHeight)
        .glassSurface(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous), fallback: .regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .panelDidShow)) { _ in
            detail = nil
            searchFocused = true
        }
    }

    // MARK: List

    private var loaded: LinearStore.Loaded { store.loaded(for: store.current) }

    private var issues: [Issue] {
        IssueList.visible(loaded.result?.issues ?? [], query: search, sortKey: store.sortKey, hideDone: store.hideDone)
    }

    private var list: some View {
        VStack(spacing: 10) {
            header
            searchField
            content
        }
        .padding(Metrics.panelPadding)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.usableViews) { view in
                    Button {
                        search = ""
                        store.select(view)
                    } label: {
                        if view.id == store.current?.id {
                            Label(view.name, systemImage: "checkmark")
                        } else {
                            Text(view.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(store.current?.name ?? "Linear Views")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: Metrics.iconButton)
                .contentShape(Capsule())
                .glassSurface(in: Capsule(), interactive: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Linear View")

            if let result = loaded.result {
                Text("\(issues.count) of \(result.issues.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            GlassGroup {
                HStack(spacing: 6) {
                    sortMenu
                    GlassIconButton(symbol: "arrow.clockwise", help: "Refresh View (⌘R)", spinning: loaded.isLoading) {
                        store.refresh()
                    }
                    GlassIconButton(symbol: "gearshape", help: "Configure Linear Views (⌘,)", action: actions.openSettings)
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $store.sortKey) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Hide Completed & Canceled", isOn: $store.hideDone)
        } label: {
            Image(systemName: store.hideDone || store.sortKey != .manual
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium))
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .contentShape(Circle())
                .glassSurface(in: Circle(), interactive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort & Filter")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search all issues in this view…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit(openSelection)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onChange(of: search) { _, _ in selection = issues.first?.id }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassSurface(in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if store.apiKey.isEmpty {
            Notice(symbol: "key", title: "Connect Linear",
                   message: "Add a Linear API Key in Settings to see your views’ tasks here. Create a personal key in Linear → Settings → Security & access.",
                   action: ("Open Settings", actions.openSettings))
        } else if store.usableViews.isEmpty {
            Notice(symbol: "list.bullet", title: "Configure your views",
                   message: "Add a name and URL for at least one Linear issue view in Settings.",
                   action: ("Open Settings", actions.openSettings))
        } else if let error = loaded.error {
            Notice(symbol: "exclamationmark.triangle", title: "Unable to Load View", message: error,
                   action: ("Try Again", { store.refresh() }))
        } else if loaded.result == nil {
            Notice(symbol: nil, title: "Loading View…", message: nil, action: nil)
        } else if issues.isEmpty {
            Notice(symbol: "tray", title: search.isEmpty ? "No Issues in This View" : "No Matching Issues",
                   message: search.isEmpty ? nil : "Try another title, identifier, status, project, or assignee.",
                   action: nil)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(issues) { issue in
                            IssueRow(issue: issue, isSelected: issue.id == selection)
                                .id(issue.id)
                                .onTapGesture { open(issue) }
                                .onHover { if $0 { selection = issue.id } }
                                .contextMenu {
                                    Button("Open in Browser") { openInBrowser(issue) }
                                    Button("Copy Issue Link") { copyLink(issue) }
                                }
                        }
                    }
                    .padding(Metrics.rowInset)
                }
                .card()
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func move(_ step: Int) {
        let ids = issues.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        selection = ids[min(max(index + step, 0), ids.count - 1)]
    }

    private func openSelection() {
        if let issue = issues.first(where: { $0.id == selection }) ?? issues.first {
            open(issue)
        }
    }

    private func open(_ issue: Issue) {
        selection = issue.id
        detail = issue
        store.loadOptions(for: issue.team.id)
    }
}

// MARK: - Rows

private struct IssueRow: View {
    let issue: Issue
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            StateDot(color: issue.state.color, type: issue.state.type)
            Text(issue.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(issue.identifier)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            if let due = issue.dueDate {
                DueLabel(date: due, isDone: issue.isDone)
            }
            Text(issue.state.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .background(
            isSelected ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

/// A due date, in red once it has passed on an open issue.
struct DueLabel: View {
    let date: String
    let isDone: Bool

    var body: some View {
        let overdue = !isDone && date < timelessDate(Date())
        Label(date, systemImage: "calendar")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            .help("Due date")
    }
}

/// Linear's status glyph, reduced to a dot filled to the stage's progress.
struct StateDot: View {
    let color: String
    let type: String

    var body: some View {
        let tint = Color(hex: color) ?? .secondary
        ZStack {
            Circle().strokeBorder(tint, lineWidth: 1.5)
            switch type {
            case "completed":
                Circle().fill(tint)
                Image(systemName: "checkmark").font(.system(size: 6, weight: .black)).foregroundStyle(.white)
            case "canceled":
                Circle().fill(tint)
                Image(systemName: "xmark").font(.system(size: 6, weight: .black)).foregroundStyle(.white)
            case "started":
                Circle().trim(from: 0, to: 0.5).fill(tint).rotationEffect(.degrees(-90)).padding(3)
            case "backlog", "triage":
                Circle().strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            default:
                EmptyView()
            }
        }
        .frame(width: 12, height: 12)
    }
}

private struct Notice: View {
    let symbol: String?
    let title: String
    let message: String?
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                GlassPillButton(title: action.0, action: action.1)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

func openInBrowser(_ issue: Issue) {
    if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
}

func copyLink(_ issue: Issue) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(issue.url, forType: .string)
    HUD.shared.show("Copied Issue Link")
}

extension Color {
    /// Linear sends colours as "#rrggbb".
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255,
                  blue: Double(number & 0xFF) / 255)
    }
}

extension Notification.Name {
    static let panelDidShow = Notification.Name("panelDidShow")
}

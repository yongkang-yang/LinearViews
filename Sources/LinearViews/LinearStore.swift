// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LinearViewsKit

/// Settings, the loaded views and the issue edits. Views read everything from here.
@MainActor
final class LinearStore: ObservableObject {
    static let apiKeyAccount = "apiKey"
    private enum Keys {
        static let views = "views"
        static let defaultView = "defaultView"
        static let selectedView = "selectedView"
        static let sortKey = "issueSortKey"
        static let thenSortKey = "issueThenSortKey"
        static let hideDone = "hideDoneIssues"
    }

    @Published var views: [SavedView] { didSet { saveViews() } }
    @Published var defaultViewID: UUID? { didSet { UserDefaults.standard.set(defaultViewID?.uuidString, forKey: Keys.defaultView) } }
    @Published private(set) var selectedViewID: UUID?
    @Published var sortKey: SortKey {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: Keys.sortKey)
            // The second key is never the first one again.
            if thenSortKey == sortKey { thenSortKey = .manual }
        }
    }
    /// Orders issues the first key ties on; `.manual` means none.
    @Published var thenSortKey: SortKey { didSet { UserDefaults.standard.set(thenSortKey.rawValue, forKey: Keys.thenSortKey) } }
    @Published var hideDone: Bool { didSet { UserDefaults.standard.set(hideDone, forKey: Keys.hideDone) } }
    @Published var apiKey: String {
        didSet {
            Keychain.write(apiKey, for: Self.apiKeyAccount)
            results = [:]
        }
    }

    struct Loaded {
        var result: ViewResult?
        var error: String?
        var loadedAt: Date?
        var isLoading = false
    }

    /// Keyed by view URL, so each view keeps its list while another is on screen.
    @Published private(set) var results: [String: Loaded] = [:]
    private var loads: [String: Task<Void, Never>] = [:]

    // Team-scoped picker options, fetched once per team.
    @Published private(set) var states: [String: [WorkflowState]] = [:]
    @Published private(set) var members: [String: [NamedRef]] = [:]
    @Published private(set) var projects: [String: [NamedRef]] = [:]
    @Published private(set) var optionErrors: [String: String] = [:]

    /// Opening the panel re-fetches only if the data has had time to move.
    static let staleAfter: TimeInterval = 60

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.views), let saved = try? JSONDecoder().decode([SavedView].self, from: data) {
            views = saved
        } else {
            views = SavedView.defaults
            // ToDo was the extension's default view.
            defaultViewID = SavedView.defaults.last?.id
        }
        if defaults.data(forKey: Keys.views) != nil {
            defaultViewID = defaults.string(forKey: Keys.defaultView).flatMap(UUID.init)
        }
        selectedViewID = defaults.string(forKey: Keys.selectedView).flatMap(UUID.init)
        sortKey = SortKey(rawValue: defaults.string(forKey: Keys.sortKey) ?? "") ?? .manual
        thenSortKey = SortKey(rawValue: defaults.string(forKey: Keys.thenSortKey) ?? "") ?? .manual
        hideDone = defaults.bool(forKey: Keys.hideDone)
        apiKey = Keychain.read(Self.apiKeyAccount)
        saveViews()
    }

    private func saveViews() {
        if let data = try? JSONEncoder().encode(views) {
            UserDefaults.standard.set(data, forKey: Keys.views)
        }
        UserDefaults.standard.set(defaultViewID?.uuidString, forKey: Keys.defaultView)
    }

    /// The views that can be shown; half-filled rows in Settings are skipped.
    var usableViews: [SavedView] { views.filter { $0.problem == nil } }

    /// The sort keys in order. A second key only applies under a first one,
    /// and never repeats it.
    var sortKeys: [SortKey] {
        guard sortKey != .manual else { return [] }
        return thenSortKey == .manual || thenSortKey == sortKey ? [sortKey] : [sortKey, thenSortKey]
    }

    var current: SavedView? { currentView(usableViews, selected: selectedViewID, defaultID: defaultViewID) }

    func select(_ view: SavedView) {
        selectedViewID = view.id
        UserDefaults.standard.set(view.id.uuidString, forKey: Keys.selectedView)
        refreshIfStale()
    }

    // MARK: Loading

    func loaded(for view: SavedView?) -> Loaded {
        guard let view else { return Loaded() }
        return results[view.url] ?? Loaded()
    }

    func refreshIfStale() {
        guard let view = current else { return }
        let loaded = results[view.url]
        if loaded?.isLoading == true { return }
        if let at = loaded?.loadedAt, loaded?.error == nil, Date().timeIntervalSince(at) < Self.staleAfter { return }
        refresh()
    }

    /// Reloads the complete current view. The previous list stays on screen
    /// until the new one is in.
    func refresh() {
        guard let view = current, !apiKey.isEmpty else { return }
        let url = view.url
        loads[url]?.cancel()
        results[url, default: Loaded()].isLoading = true
        let client = LinearClient(apiKey: apiKey)
        loads[url] = Task { [weak self] in
            do {
                let result = try await client.fetchView(url: url)
                self?.results[url] = Loaded(result: result, error: nil, loadedAt: Date())
            } catch is CancellationError {
                return
            } catch {
                self?.results[url]?.error = error.localizedDescription
                self?.results[url]?.result = nil
                self?.results[url]?.isLoading = false
            }
        }
    }

    // MARK: Editing

    private var client: LinearClient { LinearClient(apiKey: apiKey) }

    func loadOptions(for teamID: String) {
        guard states[teamID] == nil || members[teamID] == nil || projects[teamID] == nil else { return }
        let client = self.client
        Task { [weak self] in
            async let states = try? client.fetchTeamStates(teamID: teamID)
            async let members = try? client.fetchTeamMembers(teamID: teamID)
            async let projects = try? client.fetchTeamProjects(teamID: teamID)
            let (s, m, p) = await (states, members, projects)
            guard let self else { return }
            if let s { self.states[teamID] = s }
            if let m { self.members[teamID] = m }
            if let p { self.projects[teamID] = p }
            self.optionErrors[teamID] = s == nil || m == nil || p == nil
                ? "Some options could not be loaded from Linear." : nil
        }
    }

    /// Runs an edit and patches the issue in every loaded view, so the list
    /// reflects it without a refetch. Returns the message for the HUD.
    func edit(_ issue: Issue, _ change: (LinearClient) async throws -> (inout Issue) -> String) async -> (Issue?, String, Bool) {
        do {
            let apply = try await change(client)
            var updated = issue
            let message = apply(&updated)
            for (url, loaded) in results {
                guard var result = loaded.result, let index = result.issues.firstIndex(where: { $0.id == issue.id }) else { continue }
                result.issues[index] = updated
                results[url]?.result = result
            }
            return (updated, message, true)
        } catch {
            return (nil, error.localizedDescription, false)
        }
    }
}

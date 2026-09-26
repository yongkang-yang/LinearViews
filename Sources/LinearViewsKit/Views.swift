// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct LinearError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A saved Linear custom view, as configured in Settings.
public struct SavedView: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String

    public init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }

    /// The three views the Raycast extension came preconfigured with.
    public static let defaults = [
        SavedView(name: "Due Tomorrow", url: "https://linear.app/yongkang/view/due-tomorrow-6b38b9fce66a"),
        SavedView(name: "OverDue issues", url: "https://linear.app/yongkang/view/overdue-issues-be1ac40d9b1f"),
        SavedView(name: "ToDo", url: "https://linear.app/yongkang/view/todo-41428a79d10e"),
    ]

    /// nil when the view is usable, otherwise what to fix.
    public var problem: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty && url.isEmpty { return "Enter a name and a saved Linear View URL." }
        if name.isEmpty { return "Enter a name for this view." }
        do {
            _ = try viewSlug(url)
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}

/// The custom view's slug, which Linear's `customView(id:)` accepts.
/// Rejects other hosts and URLs carrying temporary filters: Linear applies
/// only a view's saved filters, so a filtered URL would show something else.
public func viewSlug(_ value: String) throws -> String {
    guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          components.scheme?.lowercased() == "https", components.host?.lowercased() == "linear.app",
          components.user == nil, components.password == nil
    else { throw LinearError("Use an https://linear.app/ URL.") }
    let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // "", workspace, "view", slug, and optionally "" for a trailing slash.
    let trimmed = parts.last == "" && parts.count == 5 ? Array(parts.dropLast()) : parts
    guard trimmed.count == 4, trimmed[0].isEmpty, !trimmed[1].isEmpty, trimmed[2] == "view", !trimmed[3].isEmpty
    else { throw LinearError("Use a saved Linear custom View URL.") }
    if let query = components.query, !query.isEmpty {
        throw LinearError("Save temporary filters in Linear and use the saved View URL.")
    }
    return trimmed[3].removingPercentEncoding ?? trimmed[3]
}

/// The view to show: the one last selected, else the default, else the first.
public func currentView(_ views: [SavedView], selected: UUID?, defaultID: UUID?) -> SavedView? {
    views.first { $0.id == selected } ?? views.first { $0.id == defaultID } ?? views.first
}

public enum SortKey: String, CaseIterable, Sendable {
    case manual, dueDate, status, priority, title

    public var title: String {
        switch self {
        case .manual: "View Order"
        case .dueDate: "Due Date"
        case .status: "Status"
        case .priority: "Priority"
        case .title: "Title"
        }
    }
}

public enum IssueList {
    /// Workflow stage order, earliest to latest, so sorting by status reads
    /// like a pipeline.
    static let statusRank = ["triage": 0, "backlog": 1, "unstarted": 2, "started": 3, "completed": 4, "canceled": 5]

    static func ordered(_ a: Issue, _ b: Issue, by key: SortKey) -> Bool? {
        switch key {
        case .manual:
            return nil
        case .dueDate:
            switch (a.dueDate, b.dueDate) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x == y ? nil : x < y
            }
        case .status:
            let x = statusRank[a.state.type] ?? 99, y = statusRank[b.state.type] ?? 99
            return x == y ? nil : x < y
        case .priority:
            // No priority (0) sorts last, not first.
            let x = a.priority == 0 ? 99 : a.priority, y = b.priority == 0 ? 99 : b.priority
            return x == y ? nil : x < y
        case .title:
            let result = a.title.localizedCompare(b.title)
            return result == .orderedSame ? nil : result == .orderedAscending
        }
    }

    /// Filters by the search text across title, identifier, status, project
    /// and assignee, drops finished issues if asked, and sorts. Ties keep the
    /// view's own order.
    public static func visible(_ issues: [Issue], query: String, sortKey: SortKey, hideDone: Bool) -> [Issue] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = issues.enumerated().filter { _, issue in
            if hideDone && issue.isDone { return false }
            guard !needle.isEmpty else { return true }
            return [issue.identifier, issue.title, issue.state.name, issue.project?.name, issue.assignee?.name]
                .contains { $0?.lowercased().contains(needle) ?? false }
        }
        return filtered.sorted { lhs, rhs in
            ordered(lhs.element, rhs.element, by: sortKey) ?? (lhs.offset < rhs.offset)
        }.map(\.element)
    }
}

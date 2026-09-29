// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct NamedRef: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct IssueState: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    /// triage, backlog, unstarted, started, completed or canceled.
    public let type: String

    public init(id: String, name: String, color: String, type: String) {
        self.id = id
        self.name = name
        self.color = color
        self.type = type
    }
}

public struct Issue: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let identifier: String
    public let title: String
    public let description: String?
    public let url: String
    public var dueDate: String?
    public var priority: Int
    public var priorityLabel: String
    public var state: IssueState
    public var assignee: NamedRef?
    public var project: NamedRef?
    public let team: TeamRef

    public struct TeamRef: Codable, Equatable, Sendable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public init(id: String, identifier: String, title: String, description: String? = nil, url: String,
                dueDate: String? = nil, priority: Int = 0, priorityLabel: String = "No priority",
                state: IssueState, assignee: NamedRef? = nil, project: NamedRef? = nil, team: TeamRef) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.description = description
        self.url = url
        self.dueDate = dueDate
        self.priority = priority
        self.priorityLabel = priorityLabel
        self.state = state
        self.assignee = assignee
        self.project = project
        self.team = team
    }

    public var isDone: Bool { Issue.doneStateTypes.contains(state.type) }

    static let doneStateTypes: Set<String> = ["completed", "canceled"]
}

public struct WorkflowState: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let type: String
    public let position: Double

    public var asIssueState: IssueState { IssueState(id: id, name: name, color: color, type: type) }
}

public struct ViewResult: Equatable, Sendable {
    public let id: String
    public let name: String
    public var issues: [Issue]
}

/// Linear's fixed priority scale, in the order a picker shows it.
public enum Priority {
    public static let options: [(value: Int, label: String)] = [
        (1, "Urgent"), (2, "High"), (3, "Medium"), (4, "Low"), (0, "No Priority"),
    ]
}

/// Formats a picked date the way Linear's TimelessDate expects: YYYY-MM-DD in
/// the local calendar, so picking "the 10th" never becomes the 9th in UTC.
public func timelessDate(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

public func date(fromTimeless value: String, calendar: Calendar = .current) -> Date? {
    let parts = value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}


/// A due date for the list: "09-30" in the current year, the full
/// "2027-01-05" otherwise, since the year is the same on nearly every row.
public func compactDueDate(_ value: String, now: Date = Date(), calendar: Calendar = .current) -> String {
    let year = String(format: "%04d-", calendar.component(.year, from: now))
    return value.count == 10 && value.hasPrefix(year) ? String(value.dropFirst(year.count)) : value
}

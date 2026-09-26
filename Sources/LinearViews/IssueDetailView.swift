// SPDX-License-Identifier: GPL-3.0-or-later
import LinearViewsKit
import SwiftUI

/// An issue's description and metadata. Status, priority, assignee, project
/// and due date are menus that change the issue in Linear directly.
struct IssueDetailView: View {
    @ObservedObject var store: LinearStore
    @State var issue: Issue
    let back: () -> Void
    @State private var isUpdating = false
    @State private var pickingDate = false
    @State private var pickedDate = Date()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                GlassIconButton(symbol: "chevron.left", help: "Back (Esc)", action: back)
                Text(issue.identifier)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                if isUpdating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                GlassGroup {
                    HStack(spacing: 6) {
                        GlassPillButton(title: "Copy Link", symbol: "link", shortcut: "⌘C") { copyLink(issue) }
                        GlassPillButton(title: "Open in Browser", symbol: "safari", shortcut: "↩") { openInBrowser(issue) }
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(issue.title)
                        .font(.system(size: 16, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    metadata
                    Divider().opacity(0.6)
                    if let description = issue.description, !description.isEmpty {
                        MarkdownView(description, fontSize: 12.5)
                    } else {
                        Text("No description.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(Metrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .card()
        }
        .padding(Metrics.panelPadding)
        .background(DetailKeys(back: back, open: { openInBrowser(issue) }, copy: { copyLink(issue) }))
        .onReceive(store.$results) { _ in
            // Another edit (or a refresh) may have changed this issue.
            for loaded in store.results.values {
                if let fresh = loaded.result?.issues.first(where: { $0.id == issue.id }), fresh != issue {
                    issue = fresh
                    return
                }
            }
        }
    }

    // MARK: Metadata

    private var teamID: String { issue.team.id }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            row("Status") {
                Menu {
                    options(store.states[teamID]) { states in
                        ForEach(states) { state in
                            Button { change { try await apply(state: state, $0) } } label: {
                                check(state.name, state.id == issue.state.id)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        StateDot(color: issue.state.color, type: issue.state.type)
                        Text(issue.state.name)
                    }
                }
            }
            row("Priority") {
                Menu {
                    ForEach(Priority.options, id: \.value) { option in
                        Button { change { try await apply(priority: option.value, $0) } } label: {
                            check(option.label, option.value == issue.priority)
                        }
                    }
                } label: {
                    Text(issue.priorityLabel)
                }
            }
            row("Assignee") {
                Menu {
                    Button { change { try await apply(assignee: nil, $0) } } label: { check("Unassigned", issue.assignee == nil) }
                    Divider()
                    options(store.members[teamID]) { members in
                        ForEach(members, id: \.id) { member in
                            Button { change { try await apply(assignee: member, $0) } } label: {
                                check(member.name, member.id == issue.assignee?.id)
                            }
                        }
                    }
                } label: {
                    Text(issue.assignee?.name ?? "Unassigned")
                }
            }
            row("Project") {
                Menu {
                    Button { change { try await apply(project: nil, $0) } } label: { check("No Project", issue.project == nil) }
                    Divider()
                    options(store.projects[teamID]) { projects in
                        ForEach(projects, id: \.id) { project in
                            Button { change { try await apply(project: project, $0) } } label: {
                                check(project.name, project.id == issue.project?.id)
                            }
                        }
                    }
                } label: {
                    Text(issue.project?.name ?? "No project")
                }
            }
            row("Due") {
                HStack(spacing: 6) {
                    Button {
                        pickedDate = issue.dueDate.flatMap { date(fromTimeless: $0) } ?? Date()
                        pickingDate = true
                    } label: {
                        if let due = issue.dueDate {
                            DueLabel(date: due, isDone: issue.isDone)
                        } else {
                            Text("No due date").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $pickingDate, arrowEdge: .bottom) { datePicker }
                    if issue.dueDate != nil {
                        Button { change { try await apply(dueDate: nil, $0) } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Due Date")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var datePicker: some View {
        VStack(spacing: 10) {
            DatePicker("Due Date", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if issue.dueDate != nil {
                    Button("Clear") {
                        pickingDate = false
                        change { try await apply(dueDate: nil, $0) }
                    }
                }
                Spacer()
                Button("Set Due Date") {
                    pickingDate = false
                    let value = timelessDate(pickedDate)
                    change { try await apply(dueDate: value, $0) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
                .fixedSize()
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private func options<T, Content: View>(_ items: [T]?, @ViewBuilder content: ([T]) -> Content) -> some View {
        if let items {
            content(items)
        } else if let error = store.optionErrors[teamID] {
            Text(error)
        } else {
            Text("Loading…")
        }
    }

    @ViewBuilder
    private func check(_ title: String, _ selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: Edits

    private func change(_ edit: @escaping (LinearClient) async throws -> (inout Issue) -> String) {
        guard !isUpdating else { return }
        isUpdating = true
        let original = issue
        Task {
            let (updated, message, succeeded) = await store.edit(original, edit)
            if let updated { issue = updated }
            isUpdating = false
            HUD.shared.show(message, style: succeeded ? .success : .failure)
        }
    }

    private func apply(state: WorkflowState, _ client: LinearClient) async throws -> (inout Issue) -> String {
        let result = try await client.updateState(issueID: issue.id, stateID: state.id)
        return { $0.state = result; return "Status Set to \(result.name)" }
    }

    private func apply(priority: Int, _ client: LinearClient) async throws -> (inout Issue) -> String {
        let result = try await client.updatePriority(issueID: issue.id, priority: priority)
        return { $0.priority = result.priority; $0.priorityLabel = result.label; return "Priority Set to \(result.label)" }
    }

    private func apply(assignee: NamedRef?, _ client: LinearClient) async throws -> (inout Issue) -> String {
        let result = try await client.updateAssignee(issueID: issue.id, assigneeID: assignee?.id)
        return { $0.assignee = result; return result.map { "Assigned to \($0.name)" } ?? "Unassigned" }
    }

    private func apply(project: NamedRef?, _ client: LinearClient) async throws -> (inout Issue) -> String {
        let result = try await client.updateProject(issueID: issue.id, projectID: project?.id)
        return { $0.project = result; return result.map { "Project Set to \($0.name)" } ?? "Removed from Project" }
    }

    private func apply(dueDate: String?, _ client: LinearClient) async throws -> (inout Issue) -> String {
        let result = try await client.updateDueDate(issueID: issue.id, dueDate: dueDate)
        return { $0.dueDate = result; return result.map { "Due Date Set to \($0)" } ?? "Due Date Cleared" }
    }
}

/// ↩ opens the issue in the browser, ⌘C copies its link, Esc goes back.
private struct DetailKeys: View {
    let back: () -> Void
    let open: () -> Void
    let copy: () -> Void

    var body: some View {
        ZStack {
            Button("", action: open).keyboardShortcut(.defaultAction)
            Button("", action: back).keyboardShortcut(.cancelAction)
            Button("", action: copy).keyboardShortcut("c", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

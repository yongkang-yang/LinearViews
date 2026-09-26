// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Linear's GraphQL API. The queries are the Raycast extension's, unchanged,
/// which were validated against Linear's published schema.
public struct LinearClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://api.linear.app/graphql")!

    private let apiKey: String
    private let transport: Transport

    public init(apiKey: String, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    // MARK: Queries

    static let viewQuery = """
    query LinearViewIssues($id: String!, $after: String) {
      customView(id: $id) {
        id name modelName
        issues(first: 100, after: $after) {
          nodes {
            id identifier title description url dueDate priority priorityLabel
            state { id name color type }
            assignee { id name }
            project { id name }
            team { id }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """
    static let teamStatesQuery = """
    query LinearTeamStates($teamId: String!) {
      team(id: $teamId) {
        states(first: 50) {
          nodes { id name color type position }
        }
      }
    }
    """
    static let teamMembersQuery = """
    query LinearTeamMembers($teamId: String!) {
      team(id: $teamId) {
        members(first: 100) {
          nodes { id name }
        }
      }
    }
    """
    static let teamProjectsQuery = """
    query LinearTeamProjects($teamId: String!) {
      team(id: $teamId) {
        projects(first: 100) {
          nodes { id name }
        }
      }
    }
    """
    static let updateIssueStateMutation = """
    mutation LinearUpdateIssueState($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
        issue { id state { id name color type } }
      }
    }
    """
    static let updateIssueDueDateMutation = """
    mutation LinearUpdateIssueDueDate($id: String!, $dueDate: TimelessDate) {
      issueUpdate(id: $id, input: { dueDate: $dueDate }) {
        success
        issue { id dueDate }
      }
    }
    """
    static let updateIssuePriorityMutation = """
    mutation LinearUpdateIssuePriority($id: String!, $priority: Int!) {
      issueUpdate(id: $id, input: { priority: $priority }) {
        success
        issue { id priority priorityLabel }
      }
    }
    """
    static let updateIssueAssigneeMutation = """
    mutation LinearUpdateIssueAssignee($id: String!, $assigneeId: String) {
      issueUpdate(id: $id, input: { assigneeId: $assigneeId }) {
        success
        issue { id assignee { id name } }
      }
    }
    """
    static let updateIssueProjectMutation = """
    mutation LinearUpdateIssueProject($id: String!, $projectId: String) {
      issueUpdate(id: $id, input: { projectId: $projectId }) {
        success
        issue { id project { id name } }
      }
    }
    """

    // MARK: Plumbing

    private struct GraphQLResponse<T: Decodable>: Decodable {
        struct GraphQLError: Decodable {
            struct Extensions: Decodable { let code: String? }
            let message: String?
            let extensions: Extensions?
        }
        let data: T?
        let errors: [GraphQLError]?
    }

    /// Auth, HTTP status and GraphQL error classification in one place.
    /// Callers say what to report when Linear returns a non-auth GraphQL
    /// error, since that's the one message worth being specific about.
    private func post<T: Decodable>(_ query: String, _ variables: [String: Any?], onError: String) async throws -> T {
        guard !apiKey.isEmpty else { throw LinearError("Add your Linear API Key in Settings.") }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        let encodedVariables = variables.mapValues { $0 ?? NSNull() }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": encodedVariables])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LinearError("Could not reach Linear. Check your connection, then refresh.")
        }
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw LinearError("Linear rejected this API key. Check the key and its workspace access in Settings.")
        }
        if status == 429 { throw LinearError("Linear is rate limiting requests. Wait a moment, then refresh.") }
        guard (200..<300).contains(status) else { throw LinearError("Linear returned HTTP \(status). Try refreshing.") }
        guard let body = try? JSONDecoder().decode(GraphQLResponse<T>.self, from: data) else {
            throw LinearError(onError)
        }
        if let errors = body.errors, !errors.isEmpty {
            let authError = errors.contains { error in
                let code = error.extensions?.code?.uppercased() ?? ""
                return code.contains("AUTHENTICAT") || code.contains("FORBIDDEN")
            }
            throw LinearError(authError ? "Linear rejected this API key. Check the key and its access in Settings." : onError)
        }
        guard let payload = body.data else { throw LinearError(onError) }
        return payload
    }

    // MARK: Reading

    private struct Page: Decodable {
        struct View: Decodable {
            struct Issues: Decodable {
                struct PageInfo: Decodable {
                    let hasNextPage: Bool
                    let endCursor: String?
                }
                let nodes: [Issue]
                let pageInfo: PageInfo
            }
            let id: String
            let name: String
            let modelName: String
            let issues: Issues
        }
        let customView: View?
    }

    /// Fetches every page, so search covers the whole view. A partial result
    /// is never presented as a complete view.
    public func fetchView(url: String) async throws -> ViewResult {
        let id = try viewSlug(url)
        var issues: [Issue] = []
        var seenIDs: [String: Int] = [:]
        var seenCursors: Set<String> = []
        var after: String?
        var result: ViewResult?
        repeat {
            let page: Page = try await post(Self.viewQuery, ["id": id, "after": after],
                                            onError: "Linear could not read this view. Check the View URL and that this key can access it.")
            guard let view = page.customView else {
                throw LinearError("Linear returned an incomplete response. Refresh to try again.")
            }
            guard view.modelName == "Issue" else {
                throw LinearError("This is not an issue view. Configure a Linear issue View URL.")
            }
            result = ViewResult(id: view.id, name: view.name, issues: [])
            // Pages can shift while they're read; an issue seen twice keeps
            // its first place and its latest data.
            for issue in view.issues.nodes {
                if let index = seenIDs[issue.id] {
                    issues[index] = issue
                } else {
                    seenIDs[issue.id] = issues.count
                    issues.append(issue)
                }
            }
            guard view.issues.pageInfo.hasNextPage else { break }
            guard let cursor = view.issues.pageInfo.endCursor, !seenCursors.contains(cursor) else {
                throw LinearError("Linear pagination did not advance. Refresh to try again.")
            }
            seenCursors.insert(cursor)
            after = cursor
        } while !Task.isCancelled
        try Task.checkCancellation()
        guard var result else { throw LinearError("Unable to load the view.") }
        result.issues = issues
        return result
    }

    private struct TeamNodes<Node: Decodable>: Decodable {
        struct Team: Decodable {
            struct Connection: Decodable { let nodes: [Node] }
            let states: Connection?
            let members: Connection?
            let projects: Connection?
        }
        let team: Team?
    }

    /// States are per team, sorted by their place in the team's workflow.
    public func fetchTeamStates(teamID: String) async throws -> [WorkflowState] {
        let data: TeamNodes<WorkflowState> = try await post(Self.teamStatesQuery, ["teamId": teamID],
                                                            onError: "Linear could not load this team's statuses. Try again.")
        return (data.team?.states?.nodes ?? []).sorted { $0.position < $1.position }
    }

    public func fetchTeamMembers(teamID: String) async throws -> [NamedRef] {
        let data: TeamNodes<NamedRef> = try await post(Self.teamMembersQuery, ["teamId": teamID],
                                                       onError: "Linear could not load this team's members. Try again.")
        return (data.team?.members?.nodes ?? []).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    public func fetchTeamProjects(teamID: String) async throws -> [NamedRef] {
        let data: TeamNodes<NamedRef> = try await post(Self.teamProjectsQuery, ["teamId": teamID],
                                                       onError: "Linear could not load this team's projects. Try again.")
        return (data.team?.projects?.nodes ?? []).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: Writing

    private struct IssueUpdate<T: Decodable>: Decodable {
        struct Payload: Decodable {
            let success: Bool
            let issue: T?
        }
        let issueUpdate: Payload?
    }

    /// Runs an issueUpdate mutation and unwraps its nested payload. A false
    /// `success` and a missing issue both mean the edit didn't stick.
    private func update<T: Decodable>(_ mutation: String, _ variables: [String: Any?], onError: String) async throws -> T {
        let data: IssueUpdate<T> = try await post(mutation, variables, onError: onError)
        guard let payload = data.issueUpdate, payload.success, let issue = payload.issue else {
            throw LinearError(onError)
        }
        return issue
    }

    public func updateState(issueID: String, stateID: String) async throws -> IssueState {
        struct Result: Decodable { let state: IssueState }
        let result: Result = try await update(Self.updateIssueStateMutation, ["id": issueID, "stateId": stateID],
                                              onError: "Linear could not update this issue's status. Try again.")
        return result.state
    }

    /// `dueDate` is YYYY-MM-DD, or nil to clear it.
    public func updateDueDate(issueID: String, dueDate: String?) async throws -> String? {
        struct Result: Decodable { let dueDate: String? }
        let result: Result = try await update(Self.updateIssueDueDateMutation, ["id": issueID, "dueDate": dueDate],
                                              onError: "Linear could not update this issue's due date. Try again.")
        return result.dueDate
    }

    /// `priority` is 0–4: No priority, Urgent, High, Medium, Low.
    public func updatePriority(issueID: String, priority: Int) async throws -> (priority: Int, label: String) {
        struct Result: Decodable {
            let priority: Int
            let priorityLabel: String
        }
        let result: Result = try await update(Self.updateIssuePriorityMutation, ["id": issueID, "priority": priority],
                                              onError: "Linear could not update this issue's priority. Try again.")
        return (result.priority, result.priorityLabel)
    }

    /// nil unassigns.
    public func updateAssignee(issueID: String, assigneeID: String?) async throws -> NamedRef? {
        struct Result: Decodable { let assignee: NamedRef? }
        let result: Result = try await update(Self.updateIssueAssigneeMutation, ["id": issueID, "assigneeId": assigneeID],
                                              onError: "Linear could not update this issue's assignee. Try again.")
        return result.assignee
    }

    /// nil removes the issue from its project.
    public func updateProject(issueID: String, projectID: String?) async throws -> NamedRef? {
        struct Result: Decodable { let project: NamedRef? }
        let result: Result = try await update(Self.updateIssueProjectMutation, ["id": issueID, "projectId": projectID],
                                              onError: "Linear could not update this issue's project. Try again.")
        return result.project
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import LinearViewsKit

/// Ported from the Raycast extension's tests/client.test.cjs.
final class LinearClientTests: XCTestCase {
    private let url = "https://linear.app/yongkang/view/todo-41428a79d10e"

    private final class Calls: @unchecked Sendable {
        var bodies: [[String: Any]] = []
        var headers: [[String: String]] = []
    }

    private func node(_ id: String) -> [String: Any] {
        ["id": id, "identifier": id.uppercased(), "title": id, "description": NSNull(), "url": "https://linear.app/i/\(id)",
         "dueDate": NSNull(), "priority": 0, "priorityLabel": "No priority",
         "state": ["id": "s", "name": "Todo", "color": "#fff", "type": "unstarted"],
         "assignee": NSNull(), "project": NSNull(), "team": ["id": "t"]]
    }

    private func page(_ ids: [String], more: Bool = false, cursor: String? = nil, model: String = "Issue") -> [String: Any] {
        ["data": ["customView": ["id": "view", "name": "ToDo", "modelName": model,
                                 "issues": ["nodes": ids.map(node),
                                            "pageInfo": ["hasNextPage": more, "endCursor": cursor.map { $0 as Any } ?? NSNull()]]]]]
    }

    /// A client whose transport answers each request with `respond`.
    private func client(key: String = "test-key", calls: Calls = Calls(),
                        _ respond: @escaping @Sendable (Int, [String: Any]) -> (Any, Int)) -> LinearClient {
        LinearClient(apiKey: key) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            calls.bodies.append(body)
            calls.headers.append(request.allHTTPHeaderFields ?? [:])
            XCTAssertEqual(request.url, LinearClient.endpoint)
            let (json, status) = respond(calls.bodies.count, body["variables"] as? [String: Any] ?? [:])
            let data = try JSONSerialization.data(withJSONObject: json)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func assertThrows(_ pattern: String, _ body: () async throws -> Void, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error matching \(pattern)", line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(pattern), "\(error.localizedDescription)", line: line)
        }
    }

    func testURLRegistryRejectsWrongHostsRoutesAndFilters() throws {
        XCTAssertEqual(try viewSlug(url), "todo-41428a79d10e")
        XCTAssertEqual(try viewSlug(url + "/"), "todo-41428a79d10e")
        for bad in ["https://linear.app.evil.test/a/view/b", "http://linear.app/a/view/b", "https://linear.app/a/views/issues",
                    url + "?filter=abc", "https://user:pass@linear.app/a/view/b"] {
            XCTAssertThrowsError(try viewSlug(bad), bad)
        }
        XCTAssertNil(SavedView(name: "ToDo", url: url).problem)
        XCTAssertNotNil(SavedView(name: "Incomplete", url: "").problem)
        let views = [SavedView(name: "ToDo", url: url)]
        XCTAssertEqual(currentView(views, selected: UUID(), defaultID: UUID())?.url, url)
    }

    func testLoadsEveryPageAndDeduplicatesChangedPages() async throws {
        let calls = Calls()
        let client = client(key: " test-key ", calls: calls) { count, _ in
            (count == 1 ? self.page(["a", "b"], more: true, cursor: "cursor1") : self.page(["b", "c"]), 200)
        }
        let result = try await client.fetchView(url: url)
        XCTAssertEqual(result.issues.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(calls.bodies.map { ($0["variables"] as? [String: Any])?["after"] as? String }, [nil, "cursor1"])
        XCTAssertEqual((calls.bodies[0]["variables"] as? [String: Any])?["id"] as? String, "todo-41428a79d10e")
        XCTAssertFalse((calls.bodies[0]["query"] as? String ?? "").contains("filter:"))
        XCTAssertEqual(calls.headers[0]["Authorization"], "test-key")
    }

    func testRejectsPartialGraphQLData() async {
        var body = page(["a"])
        body["errors"] = [["message": "secret server details"]]
        let client = client { [body] _, _ in (body, 200) }
        await assertThrows("could not read this view") { _ = try await client.fetchView(url: self.url) }
    }

    func testRejectsPaginationLoops() async {
        let client = client { _, _ in (self.page(["a"], more: true, cursor: "same"), 200) }
        await assertThrows("pagination did not advance") { _ = try await client.fetchView(url: self.url) }
    }

    func testClassifiesAuthenticationAndRateLimits() async {
        await assertThrows("rejected this API key") {
            _ = try await self.client { _, _ in ([:], 401) }.fetchView(url: self.url)
        }
        await assertThrows("rate limiting") {
            _ = try await self.client { _, _ in ([:], 429) }.fetchView(url: self.url)
        }
        await assertThrows("rejected this API key") {
            _ = try await self.client { _, _ in (["errors": [["message": "x", "extensions": ["code": "AUTHENTICATION_ERROR"]]]], 200) }
                .fetchView(url: self.url)
        }
    }

    func testStopsCancelledRequestsBeforePublishingResults() async {
        let client = client { _, _ in (self.page(["old-view"]), 200) }
        let task = Task { () -> ViewResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.fetchView(url: url)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRejectsNonIssueViewsAndMissingCredentials() async {
        await assertThrows("not an issue view") {
            _ = try await self.client { _, _ in (self.page([], model: "Project"), 200) }.fetchView(url: self.url)
        }
        await assertThrows("Add your Linear API Key") {
            _ = try await self.client(key: "") { _, _ in ([:], 200) }.fetchView(url: self.url)
        }
    }

    func testFetchesTeamStatesSortedByPosition() async throws {
        let client = client { _, _ in
            (["data": ["team": ["states": ["nodes": [
                ["id": "done", "name": "Done", "color": "#000", "type": "completed", "position": 2],
                ["id": "todo", "name": "Todo", "color": "#000", "type": "unstarted", "position": 1],
            ]]]]], 200)
        }
        let states = try await client.fetchTeamStates(teamID: "team1")
        XCTAssertEqual(states.map(\.id), ["todo", "done"])
    }

    func testUpdatesIssueStateAndSurfacesFailures() async throws {
        // issueUpdate nests its result under an "issueUpdate" payload, not a
        // bare "issue" field: that mismatch once made every successful update
        // report failure.
        let ok = client { _, variables in
            XCTAssertEqual(variables["id"] as? String, "issue1")
            XCTAssertEqual(variables["stateId"] as? String, "state1")
            return (["data": ["issueUpdate": ["success": true, "issue": [
                "id": "issue1", "state": ["id": "state1", "name": "Done", "color": "#000", "type": "completed"]]]]], 200)
        }
        let state = try await ok.updateState(issueID: "issue1", stateID: "state1")
        XCTAssertEqual(state.name, "Done")
        await assertThrows("could not update this issue's status") {
            _ = try await self.client { _, _ in (["data": ["issueUpdate": ["success": false, "issue": NSNull()]]], 200) }
                .updateState(issueID: "issue1", stateID: "state1")
        }
        await assertThrows("could not update this issue's status") {
            _ = try await self.client { _, _ in (["errors": [["message": "nope"]]], 200) }
                .updateState(issueID: "issue1", stateID: "state1")
        }
    }

    func testUpdatesDueDateIncludingClearing() async throws {
        let set = client { _, variables in
            XCTAssertEqual(variables["dueDate"] as? String, "2026-09-10")
            return (["data": ["issueUpdate": ["success": true, "issue": ["id": "issue1", "dueDate": "2026-09-10"]]]], 200)
        }
        let dueDate = try await set.updateDueDate(issueID: "issue1", dueDate: "2026-09-10")
        XCTAssertEqual(dueDate, "2026-09-10")
        let clear = client { _, variables in
            XCTAssertTrue(variables["dueDate"] is NSNull)
            return (["data": ["issueUpdate": ["success": true, "issue": ["id": "issue1", "dueDate": NSNull()]]]], 200)
        }
        let cleared = try await clear.updateDueDate(issueID: "issue1", dueDate: nil)
        XCTAssertNil(cleared)
    }

    func testFetchesMembersAndProjectsSortedByName() async throws {
        let members = try await client { _, _ in
            (["data": ["team": ["members": ["nodes": [["id": "u2", "name": "Zoe"], ["id": "u1", "name": "Amy"]]]]]], 200)
        }.fetchTeamMembers(teamID: "team1")
        XCTAssertEqual(members.map(\.name), ["Amy", "Zoe"])
        let projects = try await client { _, _ in
            (["data": ["team": ["projects": ["nodes": [["id": "p2", "name": "Zeta"], ["id": "p1", "name": "Alpha"]]]]]], 200)
        }.fetchTeamProjects(teamID: "team1")
        XCTAssertEqual(projects.map(\.name), ["Alpha", "Zeta"])
    }

    func testUpdatesPriorityAssigneeAndProject() async throws {
        let priority = try await client { _, variables in
            XCTAssertEqual(variables["priority"] as? Int, 1)
            return (["data": ["issueUpdate": ["success": true, "issue": ["id": "issue1", "priority": 1, "priorityLabel": "Urgent"]]]], 200)
        }.updatePriority(issueID: "issue1", priority: 1)
        XCTAssertEqual(priority.label, "Urgent")
        let assignee = try await client { _, variables in
            XCTAssertTrue(variables["assigneeId"] is NSNull)
            return (["data": ["issueUpdate": ["success": true, "issue": ["id": "issue1", "assignee": NSNull()]]]], 200)
        }.updateAssignee(issueID: "issue1", assigneeID: nil)
        XCTAssertNil(assignee)
        let project = try await client { _, variables in
            XCTAssertEqual(variables["projectId"] as? String, "p1")
            return (["data": ["issueUpdate": ["success": true, "issue": ["id": "issue1", "project": ["id": "p1", "name": "Alpha"]]]]], 200)
        }.updateProject(issueID: "issue1", projectID: "p1")
        XCTAssertEqual(project?.name, "Alpha")
    }
}

final class IssueListTests: XCTestCase {
    private func issue(_ id: String, due: String? = nil, priority: Int = 0, type: String = "unstarted") -> Issue {
        Issue(id: id, identifier: id, title: id, url: "https://linear.app/i/\(id)", dueDate: due, priority: priority,
              state: IssueState(id: type, name: type.capitalized, color: "#000", type: type), team: .init(id: "t"))
    }

    func testSortsAndKeepsViewOrderForTies() {
        let issues = [issue("c", due: "2026-10-02", priority: 0, type: "started"),
                      issue("a", due: nil, priority: 2, type: "backlog"),
                      issue("b", due: "2026-10-01", priority: 1, type: "completed")]
        XCTAssertEqual(IssueList.visible(issues, query: "", sortKey: .manual, hideDone: false).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(IssueList.visible(issues, query: "", sortKey: .dueDate, hideDone: false).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(IssueList.visible(issues, query: "", sortKey: .priority, hideDone: false).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(IssueList.visible(issues, query: "", sortKey: .status, hideDone: false).map(\.id), ["a", "c", "b"])
        XCTAssertEqual(IssueList.visible(issues, query: "", sortKey: .title, hideDone: true).map(\.id), ["a", "c"])
    }

    func testSearchesStatusToo() {
        let issues = [issue("a", type: "backlog"), issue("b")]
        XCTAssertEqual(IssueList.visible(issues, query: " BACKLOG ", sortKey: .manual, hideDone: false).map(\.id), ["a"])
    }

    func testTimelessDateUsesTheLocalCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 0, minute: 30))!
        XCTAssertEqual(timelessDate(date, calendar: calendar), "2026-09-10")
    }
}

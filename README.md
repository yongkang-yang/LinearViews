# Linear Views

A native macOS menu bar app for the issues in your saved Linear custom views.
It is the native rewrite of the
[Linear Views](https://github.com/yongkang-yang/raycast-linear-views) Raycast
extension, without Raycast running underneath it.

## Use

- **Click** the Linear icon in the menu bar for a Liquid Glass panel with the
  current view's issues. **Right-click** it to switch views, or to reach Settings
  and Quit. An optional global shortcut (Settings → General) shows and hides the
  panel from any app.
- The view picker at the top left switches between saved views; the current view
  is remembered.
- Type to search by title, identifier, status, project or assignee. `↑`/`↓` move
  through the list, `↩` opens an issue.
- The details show the description (Markdown) and metadata. **Status**,
  **Priority**, **Assignee**, **Project** and **Due** are menus that change the
  issue in Linear directly; status, assignee and project options are scoped to the
  issue's team. The list reflects the change without a refetch.
- In the details, `↩` opens the issue in the browser, `⌘C` copies its link, and
  `esc` goes back. Right-click a row for the same two actions from the list.
- The sort & filter button sorts by view order, due date, status, priority or
  title, and hides completed and canceled issues. Both choices are remembered.
- `⌘R` refreshes the view. Opening the panel refreshes it on its own when the
  list is more than a minute old, and keeps the old list on screen meanwhile.
- Overdue dates on open issues are shown in red.

The app calls Linear's `customView(id: slug).issues`, so Linear applies the saved
view's filters. It fetches every page before showing a result, and never shows a
partial list as complete. It does not reproduce Linear's board grouping or custom
display ordering. URLs with temporary query filters are rejected; save those
filters in Linear and use the saved URL.

## Setup

Open Linear Views; Settings opens on first run.

1. **Views** tab → **Linear API Key**: a personal key from Linear → Settings →
   Security & access, with read and write access to the teams in your views (write
   is used only for edits from the details). It is kept in the login keychain and
   sent only to `https://api.linear.app/graphql`.
2. Add, edit, reorder and remove views (there's no eight-view limit any more).
   The starred view is shown until you pick another.

Preconfigured, as in the extension: **Due Tomorrow**, **OverDue issues** and
**ToDo** (default).

### Moving over from the Raycast extension

Raycast keeps extension preferences encrypted, so copy them by hand: open Raycast
→ Settings → Extensions → Linear Views and carry the **Linear API Key** and any
view names/URLs you changed from the defaults into the Views tab.

## Build

Requires macOS 14+ and Xcode (Swift 6 toolchain). Liquid Glass needs macOS 26;
older systems get a material fallback.

```sh
swift test               # URL handling, pagination, errors, edits, sorting
./Scripts/bundle.sh      # → build/LinearViews.app, installed in /Applications
```

The tests are the extension's `tests/client.test.cjs`, ported: URL validation,
pagination and de-duplication, partial responses, repeated cursors,
authentication and rate limits, cancellation, non-issue views and missing keys,
and the status/due-date/priority/assignee/project updates. The GraphQL documents
are the extension's, unchanged, which were validated against Linear's published
schema.

`bundle.sh` wraps the binary in an `.app`, signs it with your Developer ID or
Apple Development certificate (falling back to ad-hoc; set `CODESIGN_IDENTITY`
to choose one) and installs it over `/Applications/LinearViews.app`, quitting and
relaunching a running copy. Pass `--no-install` to stop at `build/`. The icon is
drawn by `swift Scripts/make-icon.swift`.

## License

[GPL-3.0-or-later](LICENSE). Linear and its logo are trademarks of Linear Orbit,
Inc.; this is an unofficial client.

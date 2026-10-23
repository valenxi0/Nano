# Add Cue sync to your app

Hand this whole file to the coding agent working in your app's repository. It
is everything needed to let Nano's Cue list sync with your app's tasks.

## What you're building

Nano is a macOS app. Cue is its list of to-dos, prompts, ideas and links,
grouped into folders. Cue syncs with outside apps through a small MCP server
that the outside app runs while it is open. The user connects it in Nano under
Settings > Cue > Sync > Custom by pasting the server's address (and a token,
if your app uses one), then picks which of your projects each Cue folder maps
to. From then on, tasks sync both ways within a few seconds.

Your app needs to:

1. Serve five MCP tools (below) over Streamable HTTP on this Mac.
2. Remember which of its tasks belong to which cue, so a retry never makes a
   duplicate.
3. Report what changed since a cursor, including deletions.

Nano does the merging, conflict handling and retries. Your app only answers
the five tools correctly.

## Steps for the agent

1. **Read the app first.** Find the task model, how tasks are grouped
   (projects, lists, areas), where they are stored, what records changes
   (`updated_at`, a version or sequence number, an event log), and whether
   the app already runs a local HTTP or MCP server. If it does, add the tools
   to it rather than start a second one.
2. **Write a short mapping** from Cue's fields to the app's, using the table
   below, and note any field the app lacks. Ask the user only about real
   conflicts; otherwise pick the simplest mapping.
3. **Add a link store**: (source, external_id) to task ID, unique on
   (source, external_id). A table, a column, or a JSON field all work.
4. **Choose the change cursor.** Best is a number that only goes up (a
   sequence, an event log position, a revision counter). Otherwise use
   `updated_at` plus task ID as a tiebreak. Deletions need a tombstone (or a
   soft-delete flag) that the change feed can report.
5. **Serve the tools** on `http://127.0.0.1:<port>/mcp` while the app runs.
   Use the app's MCP library if it has one; otherwise the raw exchange below
   is small enough to write by hand.
6. **Pick auth.** Simplest: the app shows a token in its settings for the user
   to paste into Nano. If the app already does MCP OAuth, keep it; Nano
   supports it (details below). Without either, anything on the Mac could
   change the user's tasks.
7. **Pick capabilities.** `two_way` always. Add `all_kinds` if the app can
   hold prompts and ideas as well as to-dos, and `images` if it can attach
   images to a task.
8. **Show the connection details** in the app's settings: the address to
   paste into Nano, and the token if there is one.
9. **Test** with the checklist at the end.

### Field mapping

| Cue | Your app | Notes |
|---|---|---|
| `title` | task title | First line of the cue. |
| `notes` | description / notes | Rest of the cue; may be empty. |
| `done` | completed / status | `done: false` should leave other non-done states (e.g. "in progress") alone. |
| `project_id` | project / list ID | Tasks with no project can map to a pseudo-project such as `"inbox"`. |
| `kind` | a field or label you add | Only with `all_kinds`: `todo`, `prompt`, `idea`, `link`. |
| `images` | attachments | Only with `images`. Cue to app only. |
| `updated_at` | last-modified time | RFC 3339. Used to break title conflicts. |
| `deleted` | deleted / archived | Archiving is fine; report it as deleted. |
| `external_id` | your link store | The cue's UUID. |

Everything else your tasks have (dates, priority, tags, subtasks, checklists)
is left alone by Cue. Sync top-level tasks only if subtasks would confuse the
mapping.

## Connecting

- **Transport:** MCP Streamable HTTP. Nano POSTs JSON-RPC to the address and
  accepts a reply as `application/json` or as `text/event-stream`.
- **Handshake:** Nano sends `initialize` (protocol version `2025-06-18`), then
  `notifications/initialized`, then `tools/list` and `tools/call`.
- **Sessions:** if the server returns an `Mcp-Session-Id` header, Nano sends it
  back on every request, and starts a new session if the server answers 404.
- **Address:** plain `http` is accepted only for `localhost`, `127.0.0.1` and
  `::1`. Anything else must be `https`.
- **Auth**, either of:
  - **A token the user pastes.** Every request then carries
    `Authorization: Bearer <token>`. Answer 401 or 403 to reject it.
  - **MCP's standard sign-in**, used when the user leaves the token empty and
    the server answers 401:
    1. Nano reads `/.well-known/oauth-protected-resource`, first with the MCP
       path appended, then without.
    2. It reads the authorization server's
       `/.well-known/oauth-authorization-server`.
    3. It registers itself at `registration_endpoint` with the redirect URI
       `nano://cue/oauth`. Your server must accept a custom-scheme redirect URI.
    4. It opens `authorization_endpoint` in the browser: authorization code,
       PKCE `S256`, `state`, `resource`.
    5. It exchanges the code at `token_endpoint` as a public client, with no
       secret.

    Return a `refresh_token`. Nano refreshes when the access token expires or
    a request gets 401, and asks the user to sign in again only if refreshing
    fails.

Nano treats the server as a Cue sync app only if `tools/list` includes at
least `cue_describe`, `cue_list_projects` and `cue_upsert_task`. Two-way sync
also needs `cue_list_changes` and `cue_delete_task`.

## Tool results

Return each result as `structuredContent`. For older clients, also put the
same JSON as a text block in `content`. Report a failure with `isError: true`
and a text block saying what went wrong.

Times are RFC 3339 strings, e.g. `2026-10-22T18:04:05Z`. IDs are strings.
Cursors are opaque strings Nano hands back unchanged.

## Tools

### `cue_describe`

No arguments.

```json
{ "name": "My App", "protocol_version": 1, "capabilities": ["two_way"] }
```

`name` is shown in Nano's Settings. Capabilities, all optional:

- `"two_way"`: Cue may sync folders with the app. Without it, the app only
  receives cues the user sends with "Send to".
- `"all_kinds"`: the app takes prompts, ideas and links as well as to-dos.
  Cue then syncs every cue in a linked folder, not only to-dos, and sends
  `kind` on `cue_upsert_task`. Return `kind` in `cue_list_changes` if your
  app lets people change it.
- `"images"`: the app takes a cue's images. Cue then sends `images` on
  `cue_upsert_task` whenever a cue's image set changes. Images go one way,
  from Cue to the app.

Nano sends `kind` and `images` only to apps that list these capabilities, so
an app without them never sees the extra arguments.

### `cue_list_projects`

No arguments. The lists or projects a Cue folder can map to.

```json
{ "projects": [ { "project_id": "p1", "name": "Work" } ] }
```

### `cue_upsert_task`

Creates a task, or updates it if it already exists.

```json
{
  "external_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "source": "cue",
  "task_id": "t42",
  "title": "Book flights",
  "notes": "Window seat",
  "project_id": "p1",
  "done": false
}
```

- `external_id` is the cue's UUID; compare it case-insensitively. **Dedupe on
  (`source`, `external_id`)**: a second call with the same pair updates the
  same task. Nano relies on this to retry safely after a crash.
- `task_id` is optional. When present, update that task and remember the
  `external_id` on it. Nano uses this to attach a cue to a task that was
  created in your app.
- `notes` is optional and may be empty.
- Moving a task to another `project_id` is an ordinary update.
- `kind` (with `"all_kinds"`): `"todo"`, `"prompt"`, `"idea"` or `"link"`.
- `images` (with `"images"`): the cue's whole image set, as
  `[{ "name": "3F2A….png", "mime_type": "image/png", "data": "<base64>" }]`.
  Replace whatever the task had. Missing means unchanged; an empty array means
  the cue's images were removed. Screenshots can be several megabytes each, so
  allow request bodies of at least 25 MB.

```json
{ "task_id": "t42", "updated_at": "2026-10-22T18:04:05Z" }
```

### `cue_list_changes`

```json
{ "since": "17", "project_ids": ["p1", "p2"] }
```

`since` is missing on the first call; return every task then.

```json
{
  "tasks": [
    {
      "task_id": "t42",
      "external_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "title": "Book flights",
      "notes": "Window seat",
      "project_id": "p1",
      "done": false,
      "updated_at": "2026-10-22T18:04:05Z",
      "deleted": false,
      "kind": "todo"
    }
  ],
  "cursor": "18",
  "missing_project_ids": []
}
```

- Results are always incremental. Return every task that changed since the
  cursor; a task you leave out is taken to be unchanged, never deleted.
- `project_ids` lists the projects Nano is syncing. You may return changes in
  other projects too; Nano needs them to notice a task moved out of a synced
  project.
- Report a deleted task as a row with `"deleted": true`, at least until the
  cursor moves past it.
- `external_id` is missing (or null) for tasks created in your app. Nano
  imports open ones and then calls `cue_upsert_task` with their `task_id` to
  attach a cue UUID.
- Put any requested project that no longer exists in `missing_project_ids`.
  Nano stops syncing that folder and tells the user.

### `cue_delete_task`

```json
{ "task_id": "t42" }
```

Returns `{}`. Deleting a task that is already gone is not an error.

## The raw exchange

For an app without an MCP library. Every request is a POST of one JSON-RPC
message to the server's address.

```http
POST /mcp
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"nano","version":"1"}}}
```

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"my-app","version":"1"}}}
```

Then `{"jsonrpc":"2.0","method":"notifications/initialized"}`, which has no
`id`, so answer `202` with an empty body.

`tools/list` returns `{"tools":[{"name":"cue_describe","inputSchema":{"type":"object","properties":{}}}, …]}`.

A tool call and its reply:

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cue_list_projects","arguments":{}}}
```

```json
{"jsonrpc":"2.0","id":3,"result":{"structuredContent":{"projects":[{"project_id":"p1","name":"Work"}]},"content":[{"type":"text","text":"{\"projects\":[{\"project_id\":\"p1\",\"name\":\"Work\"}]}"}],"isError":false}}
```

Answer unknown methods with a JSON-RPC error (`-32601`). GET on the address
can answer `405`; Nano never opens a stream.

Nano's source includes a complete example server in one Python file,
`tools/cue-sync-reference-server.py`.

## How Nano uses this

- **When it syncs:** half a second after a cue changes, when the island
  opens, and on a schedule: every 5 seconds for a server on this Mac, every
  30 seconds for one elsewhere. Keep `cue_list_changes` cheap when nothing
  changed; it is called often.
- **Conflicts:** for each linked task, Nano compares Cue, your app, and the
  state at the last sync, field by field.
  - Both sides changed the title or notes: the later edit wins, using your
    `updated_at`.
  - Both changed `done`: your app wins.
- **Text:** a cue's first line is the title; the rest is the notes. A cue with
  only images is titled "Image".
- **What syncs:** only to-dos in folders the user linked to a project, unless
  the app lists `"all_kinds"`; then every cue in those folders does. Other
  cues reach you only through "Send to".

## Done when

Unit tests:

- Upserting the same `external_id` twice gives one task. `task_id` attaches a
  cue to an existing task.
- `done` maps both ways, and `done: false` keeps any other non-done status.
- A cursor returns only later changes, including deletions as
  `"deleted": true`.
- If you list `all_kinds`: `kind` round-trips. If you list `images`: a new set
  replaces the old one, an empty array clears it, and a missing key leaves it
  alone.
- A wrong or missing token gets 401.

By hand, with Nano:

1. In Nano, open Settings > Cue > Sync > Custom, then Connect.
2. Paste the address (and token).
3. Link a Cue folder to one of your projects.
4. Check, in both directions: create, complete, rename, move between linked
   projects, and delete.
5. Quit your app, edit in Cue, reopen your app: the edits arrive within a
   few seconds.

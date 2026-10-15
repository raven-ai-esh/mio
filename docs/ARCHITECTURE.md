# Architecture

Mio is a native SwiftUI/AppKit macOS app with one local owner service. A scoped MCP adapter communicates with that service through an authenticated Unix socket.

```
Human interface ───────────────┐
                             │
MCP client → stdio adapter → local owner → SQLite + FTS5
                             │                │
                             │                ├─ notes / versions / links
                             │                ├─ memory operation history
                             │                └─ immutable source fragments
                             │
                             ├─ native Swift/MLX embedding worker
                             └─ optional iCloud Drive record sync
```

## Storage and retrieval

The core maintains durable records, revision history, conflict state, audit data and an outbox. UI lists and graph snapshots are compact projections. PDF extraction and image OCR run locally; original files and precise source locators remain available.

Retrieval combines BM25 candidates and local embedding candidates using reciprocal-rank fusion. Search results are references to evidence, rather than generated answers. Semantic indexing is asynchronous and its coverage/fallback state is reported explicitly.

## Access

An agent profile has a home space and direct space connections with read or write access. Links and graph traversal never grant additional access. Reads, writes, search, historical evidence and cached replies are checked against current permissions.

The space catalog is a read projection of that profile's authorized live spaces. It contains names, IDs, descriptions, colors, an authorized organizational hierarchy and effective permissions, supports pagination, and does not create connections. Parent filters in the human interface include descendants; profile grants remain explicit.

## Note location and bulk operations

`note.move` records current location independently of immutable content revisions. Moving keeps note/revision/link/file/source IDs; delayed content edits cannot move a note back. Current ownership authorizes note versions, owned originals, fragments and outgoing links. Historical session events retain their recorded spaces. Search facets and job signatures follow the current location; a stale index job cannot publish into the old space.

Owner bulk move/status/delete validates the full selection before its transaction commits. Delete is recoverable. Drafts are local and are never implicitly published by these operations. Short wikilinks keep their established targets across moves and still disappear from the graph when their tokens are removed. Imported Markdown assets are copied from stored bytes for referenced paths and pinned to their content hash with an explicit note owner; unrelated shared originals remain in their space. Independent `note.assets` records bind these copies to content revisions, so reimport cannot override a concurrent move. Conflict resolution/restoration follows the chosen version’s bindings. Owned pin copies follow source erasure, including late replicas.

Database and record format 2 protect location projections from old readers. The app accepts format-1 archives/replicas, upgrades format-1 databases and retains their existing vectors. Older binaries must not open a format-2 database. Moves change current visibility, not owner-wide archives or material already delivered to another device.

## History

Each MCP transport has its own memory session. The operation log records request start/end, results, durations and observed response delivery. The session is not a Codex conversation. New note reads record the exact page of links and neighbor versions returned to the agent.

Historical replay distinguishes recorded evidence from the current background graph. Historical note revisions do not acquire current adjacency. Catalog references are displayed as space IDs, not as note-source buttons.

## Localization

Interface strings ship in an executable resource bundle with English and Russian tables. Language selection is a local preference: System, English or Russian. Views and notices resolve their strings from the current choice; dates use the interface locale. Data, machine statuses, IDs, sources and user-authored content remain unchanged.

## Modules

| Module | Responsibility |
| --- | --- |
| Mio | Native interface, preferences and service coordination. |
| MioCore | SQLite records, access, notes, search, sources, graph and operation history. |
| MioBridge | Authenticated local IPC and five-tool MCP adapter. |
| MioEmbeddings | Model verification/download, worker IPC and background indexing. |
| MioCloud | Optional file-provider record exchange with explicit pending/uploaded/error states. |
| MioBench | Synthetic performance and retrieval acceptance helpers. |

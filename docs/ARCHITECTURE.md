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

## Native workspace projections

Local SQLite triggers maintain section generations for catalog, memory, history, activity and delivery queue changes. The native owner requests only changed sections; the scoped MCP snapshot remains compatible. Note/session display collections are prepared outside view evaluation, and a refresh acknowledges its tokens only when the resulting snapshot is accepted. MCP activity therefore does not reload unchanged note and link metadata.

Indexing jobs are a local derived queue maintained with note projections. Indexed pending selection and SQL status aggregates replace repeated full-note scans. The initial queue migration validates compact metadata against existing signatures without discarding valid vectors. Revision/file changes, moves, restoration, model/extractor changes and retries retain their publication guards.

Semantic query encoding runs outside the store lock and transaction. Current scope and source eligibility are checked afterwards. Queued cancelled work is rejected before worker encoding; an active response is drained to keep the shared pipe aligned.

## History

Each MCP transport has its own memory session. The operation log records request start/end, results, durations and observed response delivery. The session is not a Codex conversation. New note reads record the exact page of links and neighbor versions returned to the agent.

Historical replay distinguishes recorded evidence from the current background graph. Historical note revisions do not acquire current adjacency. Catalog references are displayed as space IDs, not as note-source buttons.

Session pages apply visibility and stable ordering in SQLite before their offset/limit. Counts and byte-bounded cursors refer to the same eligible event sequence. The native session catalog batches owner aggregates instead of querying each session separately.

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

## Space colors and ordering

Spaces store a named base color or an opaque, device-independent sRGB `#RRGGBB` value. The native palette and exact HEX input share this representation with the sidebar, filters and graph. Color editing stays local to the properties sheet until Save.

Sibling order is optional `sort_order` metadata on ordinary space records. Legacy spaces fall back to name and ID; the organizational tree uses the persisted positions before that fallback. The local-owner `space.move` operation validates the source, destination, sibling anchor and source parent, rejects cycles, and commits the new parent and sibling positions in one transaction. Moving a parent carries its children through the hierarchy; note ownership, content revisions and profile grants do not change. Dropping on All memory appends to the root.

## Background queue checks

`sync.pending` resolves missing record references through SQLite existence checks against indexed entity IDs. It does not deserialize all historical note/event bodies or read full note bodies for each graph edge. Validation and application still use `validateDocument` and `canApply`; unresolved references remain pending across restart and sparse replication. Initialization and error-status checks for iCloud run outside the main actor. Unchanged index and cloud status do not publish redundant workspace updates.

Cloud status/sync use an owner-only canonical hash inventory, invalidated by record insert/update/delete triggers, instead of exporting complete history payloads every pass. Fresh FileProvider metadata and exact canonical hashes remain part of delivery proof. Unchanged files require fewer provider/binding checks; binding checks remain before data transfer and final acknowledgments. The cloud loop is independent of native refresh and backs off after errors. See [performance boundaries](PERFORMANCE.md).

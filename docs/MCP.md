# Mio MCP reference

Mio serves newline-delimited JSON-RPC over stdio with exactly five memory tools. Every operation uses a scoped agent profile and the authenticated local owner service. No owner credential is accepted as an MCP profile.

## Discover a space

Call read with:

```json
{"kind":"spaces"}
```

The catalog includes spaces[{id,name,description,color,sort_order,parent_id,child_space_ids,subtree_space_ids,path,can_read,can_write}], default_space_id, total_count, offset, limit and next_offset. Page size defaults to 50 and is capped at 200. Only authorized live spaces appear; duplicate names have separate IDs. Use the chosen ID for subsequent operations. `connections` lists visible directed access connections; `effective_for_profile` marks direct grants from the profile home. `color` is a named base color or an opaque sRGB `#RRGGBB` value. `sort_order` is the optional persisted sibling position; older spaces without an explicit position use the name/ID fallback. Hierarchy is organizational and does not grant access. To search a parent with its authorized children, pass the entry’s `subtree_space_ids` to `search.space_ids`. Hidden parents and children are omitted.

## Search

```json
{"query":"Why did we choose this design?","scope":"notes","space_ids":["SPACE_ID"],"limit":10,"max_chars":6000}
```

Use space_ids when the relevant project is known. Scope may be all, notes, files or history. Without space_ids, search uses all spaces readable by the profile. Search combines BM25 and local embeddings when available. Inspect semantic_state, search_mode and index_coverage before interpreting an incomplete result.

evidence_status=weak indicates that none of the returned content matches had word corroboration. This includes legitimate paraphrases. match_evidence identifies the channels of each hit. semantic_similarity is the embedding score for a fragment, where available. Open the exact source_id to verify important claims and keep source_group_id, revision_id and locator. Add the verified source_id or a stable HTTP(S) reference to source_ids when saving those claims.

search_timing_ms reports query encoding, keyword retrieval, source loading, ranking and coverage where applicable. The stages measure local execution and exclude MCP transport.

For a chronological history interval, use scope=history and from (inclusive) or to (exclusive), as ISO 8601 timestamps with Z or an offset such as +03:00. An empty query includes matching events without a text condition. Follow next_cursor with the same filters and profile on the same Mio instance. Pages cover events recorded before the first request, ordered by timestamp and event ID. Each page rechecks current access. Start a fresh query if the cursor expires.

```json
{"query":"","scope":"history","from":"2026-11-10T00:00:00+03:00","to":"2026-11-11T00:00:00+03:00","limit":50}
```

## Read evidence and follow links

```json
{"kind":"source","id":"SOURCE_ID"}
```

Other supported kinds are note, event and session; these require id. Current note reads include paged incoming/outgoing links with neighbor IDs and metadata. Use offset/limit and follow links_next_offset (default 50, maximum 200). Bodies of neighboring notes are read separately. Exact historical revisions omit current graph links.

File-source reads return original preview content. PDF offset is a zero-based page index. Image content is returned as a real MCP image block. URL sources are recorded references and are not fetched automatically.

## Capture, revise and link

Capture requires space_id, title, body and idempotency_key; source_ids and status are optional. An immutable PDF/image may be attached with file_name, mime_type and file_base64 together (decoded maximum 5 MB).

Revise requires note_id, expected_revision, title, body and idempotency_key. A stale revision creates a preserved conflict and reports revision_conflict; inspect and resolve it rather than reporting success.

Link requires from_note_id, to_note_id and kind. The profile must be able to write the source note and read the destination note. Linking never grants access to another space.

## Receipts and history

A mutation receipt confirms local persistence. Cloud delivery happens separately. Repeated idempotency keys must have identical content.

History records Mio memory operations and the adapter's transport lifecycle. New search events retain their effective target_space_ids. Visibility of past records and cached replies is checked against their space dependencies. A cached catalog with changed names or permissions reports catalog_changed. Request a fresh catalog in that case.

MCP schema errors report field and reason in error.data.argument_errors. Tool-level argument validation reports the same fields in structuredContent.details.argument_errors. The journal records those diagnostics and omits the submitted values for invalid history bounds and cursors.

Reconnect an already running MCP client after an application update to receive its current tool schema.

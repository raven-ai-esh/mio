# Performance in 0.5.2

The changes address repeated work as notes, recorded connections and operation history grow. SQLite remains the source of truth; the public agent interface still has five MCP tools.

## What changed

- **Prepared lists.** Session timestamps are parsed once per changed value. Opening-time and activity-time order are prepared separately, outside native view evaluation. Sidebar counts do not sort sessions. The graph's session picker also uses prepared labels, invalidated by session/profile changes, language, calendar and system time zone. Note lists reuse prepared metadata and apply space emphasis with a stable partition.
- **An incremental indexing queue.** Note projection changes schedule jobs transactionally. Idle selection reads indexed pending jobs instead of decoding every note body. Status uses aggregates and a bounded error list. Publication still validates the current revision, location, file and model signature. Valid vectors survive migration and moves; model/extractor changes, interrupted jobs and explicit retries schedule appropriate work.
- **Database-side history pages.** Access visibility, count, order, limit and offset are applied in SQLite. A page does not materialize the complete session. Existing cursor and byte bounds remain; historical replay still uses recorded source versions and issued link pages.
- **Separate inference and storage.** Query encoding happens outside the shared store lock and outside a database transaction. The result is used only after current authorization is checked. Cancelled queued requests do not start obsolete model work. An already-running worker response is allowed to finish so its shared pipe stays synchronized.
- **Section updates.** Local generation counters identify changed catalog, memory, history, activity and queue sections. MCP activity does not reload note/link metadata. Native list projections are prepared before publishing the corresponding snapshot. A generation is acknowledged only when that snapshot is accepted.
- **Smaller cloud work.** A derived, invalidated-on-write hash inventory preserves the canonical record hashes used by export and upload acknowledgments. Unchanged record payloads are not repeatedly decoded and hashed for cloud status. FileProvider metadata and account/folder checks remain authoritative. Cloud scheduling is independent of interface refresh and retries back off to a maximum five-minute delay; manual retries remain available.

## Measurements

Measured on 18 October 2026 using optimized builds on the same Apple Silicon Mac. Before is source commit `4b187738d0fdbeb52345442ece06e024c6e3f9c0`; after is the 0.5.2 implementation. Fixtures are fictional and isolated from user memory. Individual operations report the median of three warm samples; complete paged history walks report one full walk per fixture size.

| Operation and fixture | Before | After |
| --- | ---: | ---: |
| Visible session-list access, 141 sessions | 301.6 ms | 0.008 ms |
| Visible session-list access, 1,000 sessions | 3,987.7 ms | 0.039 ms |
| Visible session-list access, 5,000 sessions | 16,766.4 ms | 0.278 ms |
| Empty indexing queue, 3,200 notes | 165.2 ms | 0.023 ms |
| Index status, 3,200 notes | 162.2 ms | 0.988 ms |
| Empty indexing queue, 10,000 notes | 527.8 ms | 0.025 ms |
| Note read issued 5 ms after an index check begins, 3,200 notes | 159.6 ms | 0.733 ms |
| First 100 events of a 5,000-event session | 97.4 ms | 3.047 ms |
| Complete 5,000-event session through 100-event pages | 4,856.7 ms | 155.2 ms |

The note-index fixtures use 8,800-byte bodies. Completed jobs and current note projections are explicitly seeded to measure idle behavior, rather than ingestion or embedding quality. The session-list measurements access an already-prepared projection; initial parsing and native frame drawing are separate costs. The read overlap uses the same protocol before and after: the new idle check finishes before the delayed read starts.

Additional controlled probes on the new implementation:

- A 300 ms controlled encoder delay allowed an unrelated note read in 1.19 ms. This verifies store-lock separation and does not measure MLX inference speed.
- At 3,200 notes and 6,100 events, an MCP-only workspace delta omitted notes/links and returned about 149 KB in 34.6 ms. The complete compact snapshot was 1.65 MB and about 102 ms. This fixture has no graph edges.
- For 3,208 fictional record payloads, a warm hash inventory took 2.58 ms versus 275.6 ms for full `replica.export` on the same build. Both routes returned identical canonical hash sets. First inventory population took 292 ms and is performed away from the main actor.

These are engineering measurements of specific paths. They are not a complete-window response-time, cold filesystem, graph FPS, memory-leak, semantic quality or physical iCloud-delivery guarantee.

## Regression checks

```sh
swift test -c release
swift test --filter PerformanceStorageTests
swift test --filter SessionListTests
swift test --filter WorkerTests
swift test --filter CloudSyncTests
```

The regression suite checks bounded idle-query work and page materialization, timezone-aware ordering, typed history visibility before pagination, source-index restart/extractor/retry behavior, workspace deltas, revocation during inference, cancelled worker requests, canonical hash invalidation after redaction and internal-route access restrictions.

After packaging, run the real isolated MCP journeys described in [the build guide](BUILDING.md). Native verification must also cover notes, space emphasis, session refresh, graph inspection and recorded replay. Unit tests supplement those boundaries.

FileProvider metadata reconciliation is retained to avoid silently weakening upload proofs. Physical second-device iCloud acceptance remains a separate pending milestone.

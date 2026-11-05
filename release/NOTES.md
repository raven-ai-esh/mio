Mio 0.5.3 — first macOS binary release preparation

**Private draft: public binaries are blocked on Developer ID/notarization and
clean-Mac installation acceptance. Candidate archives are for local QA only.**

Mio is a native Mac workspace for agent memory: notes and source attachments,
linked spaces, a memory graph, version history and replayable MCP operations.

- macOS 15 or newer, Apple Silicon.
- English and Russian interface.
- Optional local embedding model download, approximately 514 MB; lexical search
  remains available before the model is installed.
- Five MCP tools: search, read, capture, revise and link, within explicitly
  authorized spaces.

The distribution includes its native embedding worker, Metal library, language
resources and third-party notices. No Xcode is required to use a final binary.
Model weights, personal memory and credentials are not included.

For install/update instructions, see `release/INSTALL.txt`. Existing memory stays
outside the app bundle; export important memory before updating. Optional iCloud
sync has not completed physical multi-device acceptance. iOS/iPadOS are not part
of this release.

Before publication, attach the notarized ZIP/DMG, committed source ZIP,
`manifest.json`, `SHA256SUMS` and installation instructions. The manifest must
match the exact release commit. [Installation feedback](https://github.com/raven-ai-esh/mio/issues).

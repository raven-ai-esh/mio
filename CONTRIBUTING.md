# Contributing

Mio is an early macOS-first project. Keep changes small, explicit and independently reviewable.

- Build and test with the instructions in docs/BUILDING.md.
- Use isolated synthetic data for tests and screenshots. Never commit personal memory, credentials, runtime configuration, model weights or local acceptance artifacts.
- Preserve source IDs, revisions, access boundaries and the distinction between a local write and cloud delivery.
- Keep the five MCP tools focused. Document and test changes to their input/output contracts.
- Verify native UI changes in the real app, including relevant language, appearance and window-size states.
- Preserve both localization tables and formatting placeholders. Switching languages must not rewrite user content or lose drafts.
- Include the observed result and executed checks in your change description. Mark unavailable external verification explicitly.

The public documentation and promotional assets are in English. The interface supports English and Russian; additional translations should use the same resource-table and preference mechanism.

# Mio development

Build and test using docs/BUILDING.md. Mio currently targets macOS; iOS and iPadOS are future work.

- Keep shipped assets inside the repository or app bundle. Discover user-selected paths at runtime.
- Use isolated synthetic memory for tests, screenshots and demonstrations. Never commit user databases, credentials, runtime configuration, model weights or local artifacts.
- History records Mio memory operations and MCP transport lifecycle. Do not discover, read or import agent chat conversations.
- Keep the five MCP tools and current access boundaries explicit. A graph edge does not grant access.
- Preserve original sources, note IDs, revisions, conflicts and user changes. Local persistence and cloud delivery are separate states.
- Keep English and Russian resource tables consistent. Language changes must preserve user content and drafts.
- Verify changed behavior at its real boundary. Native UI changes require actual app checks in the relevant language, appearance and window sizes. Substantial changes require independent adversarial review.
- Record executed checks and unresolved verification; do not infer completion from a build alone.

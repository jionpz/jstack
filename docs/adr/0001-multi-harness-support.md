# Multi-harness support: one generic adapter, native distribution per harness

jstack originally shipped only Claude Code plugins. Adding Pi, OMP, and Cursor forced three choices: keep one runtime adapter instead of per-harness translated builds; distribute through each harness's native mechanism instead of a single copy-based installer; and use the upstream Cursor-native pstack tree for Cursor while keeping the Claude Code tree for Claude Code. We picked the generic adapter because upstream already maintains the Claude Code tree and translation was rejected for maintenance cost; native distribution because each harness owns update, scope, and enablement semantics; and the native Cursor tree because it is authored for Cursor's Task/model/path semantics, whereas translating the Claude Code tree back to Cursor would add a second translation layer. The cost is two pstack trees to sync and a larger adapter document.

## Consequences

- Two pstack upstreams and locks must be synced independently.
- The adapter document carries sections for Claude Code, Pi, and OMP; Cursor native pstack does not read it.
- spec and flow ship both `.claude-plugin/plugin.json` and `.cursor-plugin/plugin.json` from one build; the two versions are rewritten together so the shared skills cannot drift by harness.
- Cursor installation is local/UI-driven, not CLI-only.
- `./jstack smoke` covers each installed harness headlessly; Cursor's interactive UI checks stay manual in `docs/testing/cursor.md`.

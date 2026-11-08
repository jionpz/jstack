# jstack must-stop list

The single list of actions that always need the user, at any size and under any autonomy grant (ADR-0004). It merges the global red lines, poteto-mode's Always-pause, and route's own list. Route and the flow hooks both read this file. Nothing else keeps a copy.

## Must stop

| Action | Hook |
|---|---|
| Recursive forced delete (`rm -rf` and its variants) | `rm-rf` |
| Force push (`--force`, `-f`, `--force-with-lease`, a `+` refspec) | `force-push` |
| Any `sudo` | `sudo` |
| Deleting or overwriting production configuration, deploys, production data | - |
| Irreversible data operations, including data deletion | - |
| Messages to customers or other outside parties | - |
| Breaking public API or schema changes | - |
| Permission or security changes | - |
| A major architecture change with no ADR | - |
| Cost, legal, or privacy exposure | - |
| A business rule or product behavior the evidence cannot settle | - |

A Hook of `-` means no command pattern can detect the action, so the agent must recognize it and ask.

## Patterns

The guard hook splits each shell command into segments at `;`, `&&`, `||`, `|`, and newlines, then matches every segment against these extended regular expressions. One line is `<hook><TAB><regex>`. A hook may have several lines; any match makes the harness ask the user before the command runs.

```patterns
rm-rf	(^|[[:space:]/])rm[[:space:]](.*[[:space:]])?(-[[:alnum:]]*[rR][[:alnum:]]*f|-[[:alnum:]]*f[[:alnum:]]*[rR])[[:alnum:]]*([[:space:]]|$)
rm-rf	(^|[[:space:]/])rm[[:space:]](.*[[:space:]])?(-[rR]|--recursive)[[:space:]](.*[[:space:]])?(-f|--force)([[:space:]]|$)
rm-rf	(^|[[:space:]/])rm[[:space:]](.*[[:space:]])?(-f|--force)[[:space:]](.*[[:space:]])?(-[rR]|--recursive)([[:space:]]|$)
force-push	(^|[[:space:]/])git[[:space:]](.*[[:space:]])?push[[:space:]](.*[[:space:]])?(--force|--force-with-lease|-[[:alnum:]]*f[[:alnum:]]*)(=[^[:space:]]*)?([[:space:]]|$)
force-push	(^|[[:space:]/])git[[:space:]](.*[[:space:]])?push[[:space:]](.*[[:space:]])?\+[^[:space:]]+
sudo	(^|[[:space:]/])sudo([[:space:]]|$)
```

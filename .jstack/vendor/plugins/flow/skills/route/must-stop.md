# jstack must-stop list

When the repository sets `must_stop_enabled: true` in `.jstack/config.json`, these actions require the user at any task size and under any autonomy grant (ADR-0004). The policy is off by default. It merges the global red lines, poteto-mode's Always-pause, and route's own list. Route and the flow hooks both read this file. Nothing else keeps a copy.

## Must stop

| Action | Hook |
|---|---|
| Recursive forced delete (`rm -rf` and its variants) | `rm-rf` |
| Force push (`--force`, `-f`, `--force-with-lease`, a `+` refspec) | `force-push` |
| Any `sudo` | `sudo` |
| Merging a pull request, or turning on auto-merge, unless the user's current message names that PR | `pr-merge` |
| Running a downloaded remote script through an interpreter (`curl` to `bash`) | `remote-pipe` |
| Hard-resetting tracked work (`git reset --hard`) | `git-reset-hard` |
| Force-cleaning untracked work (`git clean -f`) | `git-clean-force` |
| Deleting files through `find -delete` | `find-delete` |
| Staging a secret-bearing file | `stage-secret` |
| Writing an environment file that can hold secrets | `env-file` |
| Writing credentials, private keys, or provider/auth configuration | `credential-file` |
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

The guard hook splits each shell command into segments at `;`, `&&`, `||`, `|`, and newlines, then matches every segment against these extended regular expressions. One line is `<hook><TAB><regex>`; add `<TAB>full` to match the whole command instead of one segment (needed for `curl ... | bash`). A hook may have several lines. `git add` arguments are also checked against the path patterns below, so explicitly staging `.env` or another secret-bearing file is caught even though `git add` itself is not a destructive command.

Claude Code and Cursor's `beforeShellExecution` can ask before running a match; Codex and Cursor's `preToolUse` return deny, and Pi/OMP without UI block it. User approval does not make a denied command runnable on retry. Give the approved command to the user to run themselves; do not retry it through another tool or change it to evade the guard.

```patterns
rm-rf	(^|[[:space:]/])rm[[:space:]](.*[[:space:]])?(-[[:alnum:]]*[rR][[:alnum:]]*f|-[[:alnum:]]*f[[:alnum:]]*[rR])[[:alnum:]]*([[:space:]]|$)
rm-rf	(^|[[:space:]/])rm[[:space:]](.*[[:space:]])?(-[rR]|--recursive)[[:space:]](.*[[:space:]])?(-f|--force)([[:space:]]|$)
rm-rf	(^|[[:space:]/])rm[[:space:]](.*[[:space:]])?(-f|--force)[[:space:]](.*[[:space:]])?(-[rR]|--recursive)([[:space:]]|$)
force-push	(^|[[:space:]/])git[[:space:]](.*[[:space:]])?push[[:space:]](.*[[:space:]])?(--force|--force-with-lease|-[[:alnum:]]*f[[:alnum:]]*)(=[^[:space:]]*)?([[:space:]]|$)
force-push	(^|[[:space:]/])git[[:space:]](.*[[:space:]])?push[[:space:]](.*[[:space:]])?\+[^[:space:]]+
sudo	(^|[[:space:]/])sudo([[:space:]]|$)
pr-merge	(^|[[:space:]/])(gh|origin)[[:space:]](.*[[:space:]])?pr[[:space:]]+merge([[:space:]]|$)
pr-merge	(^|[[:space:]/])glab[[:space:]](.*[[:space:]])?mr[[:space:]]+merge([[:space:]]|$)
pr-merge	(^|[[:space:]/])gh[[:space:]](.*[[:space:]])?api[[:space:]].*pulls/[0-9]+/merge([[:space:]]|$)
remote-pipe	(^|[^[:alnum:]_])(curl|wget)([[:space:]]|$)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|dash|ksh|python([0-9]+(\.[0-9]+)?)?|node|ruby|perl)([[:space:]]|$)	full
git-reset-hard	(^|[[:space:]/])git[[:space:]]([^;&|]*[[:space:]])?reset[[:space:]]([^;&|]*[[:space:]])?--hard([[:space:]]|$)
git-clean-force	(^|[[:space:]/])git[[:space:]]([^;&|]*[[:space:]])?clean[[:space:]]([^;&|]*[[:space:]])?(-[[:alnum:]]*f[[:alnum:]]*|--force)([[:space:]]|$)
find-delete	(^|[[:space:]/])find([[:space:]][^;&|]*)?[[:space:]]-delete([[:space:]]|$)
```

## Path patterns

Edit tools and patch payloads are checked by path, not by file content. One line is `<hook><TAB><path regex>`; an optional third field is an allow regex. Paths are normalized to `/` separators, so the same rules work on macOS, Linux, and Windows payloads. Repository `must_stop` entries may add `path_regex` and `allow_path_regex` with the same semantics.

```path-patterns
env-file	(^|/)\.env($|\.[^/]+$)	(^|/)\.env\.(example|sample|template|dist|schema)$
credential-file	(^|/)(id_(rsa|dsa|ecdsa|ed25519)|\.npmrc|\.netrc|\.pypirc|\.git-credentials|\.aws/credentials|\.docker/config\.json|\.kube/config|credentials(\.json)?|secrets?\.(json|ya?ml|toml)|[^/]+\.(pem|key|p12|pfx|jks|keystore))$
credential-file	(^|/)(\.mcp\.json|\.codex/(config\.toml|auth\.json)|\.claude/settings(\.local)?\.json|\.cursor/(mcp\.json|cli-config\.json)|\.pi/agent/(settings\.json|trust\.json)|\.omp/agent/config\.yml|\.config/(jstack/models\.json|magpie/[^/]+))$
```

This is a tripwire, not a sandbox. A shell wrapper, an unregistered edit tool, a symlink created before the path is checked, or a harness without hooks can still get past it. Keep secrets out of the workspace and use the execution environment as the real boundary.

---
name: set-up-sandbox
description: Sets a project up with native, project-local sandboxing for coding agents — Claude Code, Codex, and Pi run directly against the repository, with the OS enforcing the boundary. No container, no image build. Produces committed config under .claude/, .codex/, and .pi/. The developer then starts the agent CLIs exactly as usual.
disable-model-invocation: true
---

# Set Up Sandbox

Give the current repository project-local, OS-enforced sandboxing for coding agents. The developer runs the same agent CLIs as always, directly against the project — no container, no separate image to build or keep current. Each agent's own sandbox carries the policy: `.claude/settings.json` for Claude Code, `.codex/config.toml` plus `.codex/rules/` for Codex, and for Pi the `pi-sandbox` plus `@gotgenes/pi-permission-system` extensions, configured under `.pi/`. The config is committed, so the repository itself defines the policy.

The security model. Each step preserves it:

> Anything inside the repository may be destroyed or leaked. Everything outside the repository must be unreachable — enforced at the OS or sandbox layer, below the model.

There are three layers, strongest first: the OS filesystem and network sandbox, command deny rules, model instructions. The first is the boundary. The second is policy on top. The third is not a security layer at all. Tell the user two consequences plainly: secrets that they cannot afford to leak do not belong in the repository (the deny globs for `.env` and key files raise the bar, they are not the boundary); and the network allowlist is porous where it includes code hosts — an agent that may reach `github.com` can push data to any repository on it.

## Invariants

A problem that you find never makes it valid to break one of these:

- Fail closed. Claude Code: `failIfUnavailable: true` and `allowUnsandboxedCommands: false`. Codex: `approval_policy = "never"`. Pi: hard denies, no ask-to-escape. A sandbox that cannot start must stop the agent, not wave it through.
- Cover the native file tools, not only Bash. Claude Code's Read/Edit/Write tools bypass the Bash sandbox; only the `permissions.deny` rules cover them. Never generate the `sandbox` block without its `permissions` block.
- The agent must not be able to edit its own policy. Sandboxed Bash is OS-blocked from `.claude/` config files; the deny rules close the native-tool path. The lasting rule for the user: review `git diff -- .claude/ .codex/ .pi/` before each session.
- Never generate or recommend the bypass flags. `--dangerously-skip-permissions` auto-approves everything the deny rules do not name; `--dangerously-bypass-approvals-and-sandbox` turns the Codex sandbox off entirely.
- Print privileged installations (`bubblewrap`, `socat`) for the human to run. Then verify them. Never run them yourself. The Pi extensions are third-party code inside the trust boundary: pin their versions, and point the user at their sources (`pi-sandbox` delegates its OS layer to a fork of Anthropic's `sandbox-runtime`) before they install.

## The conversation

Detect the OS and the installed agent CLIs. Inspect the repository for its stack. Then settle three items with the user, in conversation. Give a recommendation for each item:

1. **Platform** — macOS needs nothing. Linux and WSL2 need `bubblewrap` and `socat` (Claude Code) and `bwrap` (Codex, Pi extension); print the install command for the human. Windows outside WSL2: stop, and get the user into WSL2 first.
2. **Agents** — which of Claude Code, Codex, and Pi this project uses. Generate config only for those. For Pi, the sandbox is two extensions — core Pi has none, and project trust is not a sandbox. `pi-sandbox` is the OS boundary (bubblewrap/Seatbelt plus a filtering network proxy, and it intercepts Pi's native read/write/edit tools); `@gotgenes/pi-permission-system` is the hard-deny policy layer on top (its denies never prompt, and it parses compound commands). Install both project-locally, pinned: `pi install -l npm:pi-sandbox@<version>` and `pi install -l npm:@gotgenes/pi-permission-system@<version>` — this records them in `.pi/settings.json`, which gets committed too.
3. **Policy** — the network allowlist, from what the stack shows (for example `registry.npmjs.org` for Node, `pypi.org` and `files.pythonhosted.org` for Python, plus the git host). And the command denies: `sudo`, `su`, `doas`, `ssh`, `scp`, `git push`, and the deploy verbs are the default; whether `aws`, `gcloud`, or `kubectl` are denied outright depends on the project — ask.

If agent sandbox config already exists, this is an update. Ask what the user wants changed. Repair the existing setup. Do not recreate it.

## Generate

Fill the templates for the selected agents, resolve `{{allowed-domains}}` and the deny lists from the settled policy, and commit:

| Agent       | Destination                                        | Template                                                                        |
| ----------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| Claude Code | `.claude/settings.json`                            | [claude-settings.json](assets/templates/claude-settings.json)                   |
| Codex       | `.codex/config.toml`, `.codex/rules/security.rules` | [codex-config.toml](assets/templates/codex-config.toml), [codex-security.rules](assets/templates/codex-security.rules) |
| Pi          | `.pi/sandbox.json`, `.pi/extensions/pi-permission-system/config.json` | [pi-sandbox.json](assets/templates/pi-sandbox.json), [pi-permission-system.json](assets/templates/pi-permission-system.json) |

Three cautions while filling:

- Claude Code: `allowRead: ["."]` resolves against the project root only because the file lives in `.claude/settings.json` — never move this block to user-level settings. Broad home rules (`Read(~/**)`) do not belong in `permissions.deny`: deny beats allow, and a project under `~` would lock itself out. Deny the sensitive directories by name, as the template does.
- Codex: the permission-profile system is beta. Verify the schema against the current Codex docs when you fill the template, expect `codex` to reject stale keys after updates, and re-run the escape checks after each Codex upgrade. On Linux, unbounded `**` deny globs additionally need `glob_scan_max_depth` — consult the current permissions doc for its placement. The project config only loads once the user trusts the project in Codex; say so.
- Pi: the templates' schemas belong to the extensions, not to Pi — verify keys against the READMEs of the pinned versions before committing. Three behaviors that the templates already encode, and that must survive any edit: leave `deniedDomains` empty — a non-empty `allowedDomains` already means default-deny, and a `"*"` deny would override the allowlist and block everything; `denyWrite` must keep `.pi` — pi-permission-system's project config overrides its global config (it is not tighten-only), so this hard write-block is what stops the agent from loosening its own policy; and `denyRead` blocks `/home` and `/Users` wholesale, which works because pi-sandbox prompts (rather than hard-fails) on reads outside `allowRead` — and in print mode that prompt times out to abort, so it fails closed. One deliberate loosening sits alongside those three: `allowAllUnixSockets` ships `true`, because on Linux hosts with AppArmor's `apparmor_restrict_unprivileged_userns=1` (Ubuntu 24.04+) the `false` setting makes every Bash command fail with an `apply-seccomp`/nested-userns error. That failure is closed, not open, but it is indistinguishable from a broken install, so the template takes the working default and blocks the sockets that matter — the container-control sockets in `denyRead` — by path instead. On a host without that AppArmor restriction, tightening it back to `false` is a real improvement; confirm a Bash command still runs before you commit it.

## Prove that the sandbox holds

Run the probes through each configured agent CLI, non-interactively (`claude -p --permission-mode acceptEdits`, `codex exec`, `pi -p --approve`), and confirm the outcome from the host afterwards. A model that declines a probe proves nothing — the probe must fail at the sandbox or permission layer, with that error visible. Re-run until each result is unambiguous:

1. Read a file in `~` outside the project through the shell (`cat ~/.ssh/id_ed25519`, or any real file there) → denied.
2. The same read through the agent's native file-read tool → denied. This is the check that catches a missing `permissions` block.
3. Write outside the repository (`touch ~/sandbox-escape-check`) → denied. Confirm on the host that the file does not exist.
4. Fetch a domain outside the allowlist (`curl -sI https://example.com`) → blocked. Fetch an allowlisted domain → succeeds.
5. `sudo id` → denied. `git push --dry-run` → denied.
6. Append one character to the agent's own config (`.claude/settings.json`, `.codex/config.toml`, `.pi/permission-mode.json`) through the shell and through the native edit tool → denied. Confirm `git diff` stays clean.
7. Normal work: read a project file, write a scratch file in the repository, run the project's test command, delete the scratch file → all succeed.

A failed check is a finding. Repair, and test again. All checks must be green, for every configured agent, before the handover.

## Hand over

Tell the user: start each agent exactly as usual — `claude`, `codex`, `pi` — in this repository. The sandbox rides along; there is no wrapper script and nothing to enter. Sandboxed Bash runs without prompts (Claude Code: `autoAllowBashIfSandboxed`; Codex: `approval_policy = "never"`), so sessions are already near-autonomous. For unattended runs, give the exact commands: Claude Code `claude -p --permission-mode acceptEdits`, Codex `codex exec`, Pi `pi -p --approve` — and repeat that the bypass flags are never the answer here; they undo this setup. The lasting rules: no secrets in the repository that the user cannot lose; the developer pushes, from their own shell, after review; review `git diff -- .claude/ .codex/ .pi/` before each session; and a repository without this config has no protection — run the skill there before running an agent.

A project that genuinely needs `sudo`, system services, or native Windows is outside what this sandbox can hold. Use a disposable container or VM for that project — the container variant of this skill lives in this repository's git history.

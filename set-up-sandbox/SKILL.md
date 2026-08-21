---
name: set-up-sandbox
description: Sets a project up with native, project-local sandboxing for coding agents — Claude Code, Codex, and Pi run directly against the repository, with the OS enforcing the boundary. No container, no image build. Produces committed config under .claude/, .codex/, and .pi/. The developer then starts the agent CLIs exactly as usual.
disable-model-invocation: true
---

# Set Up Sandbox

Give the current repository project-local, OS-enforced sandboxing for coding agents — no container, no image to keep current. Each agent's own sandbox carries the policy: `.claude/settings.json` for Claude Code, `.codex/config.toml` plus `.codex/rules/` for Codex, and for Pi the `pi-sandbox` plus `@gotgenes/pi-permission-system` extensions under `.pi/`. The config is committed, so the repository itself defines the policy, and the developer starts the CLIs as usual.

The security model, which every step must preserve:

> Anything inside the repository may be destroyed or leaked. Everything outside the repository must be unreachable — enforced at the OS or sandbox layer, below the model.

What each agent actually enforces — measured by the probes below on Linux against Claude Code 2.1.238, codex-cli 0.148.0, and pi-sandbox 0.6.5 (2026-08-20), not taken from docs:

| Agent | Reads outside the repo | Writes outside the repo | Notes |
| --- | --- | --- | --- |
| Pi | blocked | blocked | Shell and native tools both. The one that meets the model in full |
| Codex | **allowed** | blocked | No sandbox mode confines reads; by design, not a misconfiguration |
| Claude Code | blocked | blocked | Shell OS-blocked (bwrap masks `$HOME`); native tools prompt-gated, failing closed in print mode, plus named deny rules. Needs the AppArmor bwrap fix on Ubuntu 24.04+ (cautions) — without it no Bash command runs at all |

Never present these as three equivalent options. If the goal is keeping the agent out of the user's other projects, say plainly that Codex cannot do it and Pi can.

Three layers, strongest first: the OS filesystem/network sandbox (the boundary), command deny rules (policy on top), model instructions (not a security layer). Egress is open by default where the agent honours the setting — Claude Code and Codex do; Pi's project-local network config did not take effect. Tell the user the two consequences plainly: secrets they cannot afford to leak do not belong in the repository (the `.env`/key deny globs raise the bar, they are not the boundary), and a prompt injection in a page the agent reads can send repository contents anywhere. An allowlist does not fix that — any admitted code host is an exfiltration channel. The filesystem boundary is unaffected by the open network and is what keeps everything else out of reach.

## Invariants

No problem you hit makes it valid to break one of these:

- Fail closed. Claude Code: `failIfUnavailable: true`, `allowUnsandboxedCommands: false`. Codex: an explicit `sandbox_mode`. Pi: hard denies, no ask-to-escape. A sandbox that cannot start must stop the agent, not wave it through.
- Never generate config that only looks like a boundary. If the shipped CLI accepts a key and then ignores it, leave it out and say so in a comment. Verify by probe; write down what the probe returned, not what the docs promise.
- Cover the native file tools, not only Bash. Claude Code's Read/Edit/Write bypass the Bash sandbox; only `permissions.deny` covers them. Never generate the `sandbox` block without its `permissions` block.
- The agent must not be able to edit its own policy. Sandboxed Bash is OS-blocked from the config files; the deny rules close the native-tool path. Lasting rule for the user: review `git diff -- .claude/ .codex/ .pi/` before each session.
- Never generate or recommend the bypass flags. `--dangerously-skip-permissions` auto-approves everything the deny rules do not name; `--dangerously-bypass-approvals-and-sandbox` turns the Codex sandbox off entirely.
- Print privileged commands (`bubblewrap`, `socat` installs, AppArmor changes) for the human to run, then verify them; never run them yourself. The Pi extensions are third-party code inside the trust boundary: pin their versions and point the user at their sources (`pi-sandbox` delegates its OS layer to a fork of Anthropic's `sandbox-runtime`) before they install.

## The conversation

Detect the OS and installed agent CLIs, inspect the repository's stack, then settle three items with the user, recommending a default for each:

1. **Platform** — macOS needs nothing. Linux and WSL2 need `bubblewrap` and `socat`; print the install command for the human. Ubuntu 24.04+ additionally needs the AppArmor bwrap fix (Claude Code cautions) for Claude Code to run at all and for Pi's tightened socket setting. Windows outside WSL2: stop, and get the user into WSL2 first.
2. **Agents** — which of the three this project uses. Generate config only for those, and show the enforcement table before they choose. For Pi the sandbox is two extensions — core Pi has none, and project trust is not a sandbox: `pi-sandbox` is the OS boundary (bubblewrap/Seatbelt plus a filtering network proxy; it also intercepts Pi's native read/write/edit tools), `@gotgenes/pi-permission-system` the hard-deny policy layer (its denies never prompt, and it parses compound commands). Install both project-locally and pinned — `pi install -l npm:pi-sandbox@<version>` and `pi install -l npm:@gotgenes/pi-permission-system@<version>` — which records them in `.pi/settings.json`, committed too.
3. **Policy** — command denies. `sudo`, `su`, `doas`, `ssh`, `scp`, `git push`, and the deploy verbs are the default; whether `aws`, `gcloud`, or `kubectl` are denied outright depends on the project — ask.

If agent sandbox config already exists, this is an update: ask what the user wants changed and repair the existing setup, don't recreate it.

## Generate

Fill the templates for the selected agents, resolve the deny lists from the settled policy, and commit:

| Agent       | Destination                                        | Template                                                                        |
| ----------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| Claude Code | `.claude/settings.json`                            | [claude-settings.json](assets/templates/claude-settings.json)                   |
| Codex       | `.codex/config.toml`, `.codex/rules/security.rules` | [codex-config.toml](assets/templates/codex-config.toml), [codex-security.rules](assets/templates/codex-security.rules) |
| Pi          | `.pi/sandbox.json`, `.pi/extensions/pi-permission-system/config.json` | [pi-sandbox.json](assets/templates/pi-sandbox.json), [pi-permission-system.json](assets/templates/pi-permission-system.json) |

### Claude Code cautions

- `allowRead: ["."]` resolves against the project root only because the file lives in `.claude/settings.json` — never move the block to user-level settings. And no broad `Read(~/**)` denies: deny beats allow, so a project under `~` would lock itself out. Deny the sensitive directories by name, as the template does.
- Deny rules for the file tools must be spelled `Edit(path)` — Claude Code does not match `Write(path)` rules in file permission checks (it warns at startup; Edit rules cover all file-editing tools). `Read(path)` rules match normally.
- The single `WebFetch(domain:*)` allow rule is what opens egress, and it does double duty: allow rules also pre-allow domains for the sandbox proxy, so it covers `curl` and `npm install` too. It only applies after the workspace trust dialog — on a headless host, set `projects["<path>"].hasTrustDialogAccepted: true` in `~/.claude.json`. To tighten later, drop it and set `sandbox.network.allowedDomains` — knowing `strictAllowlist` (which turns a miss into a block) is ignored in project settings, so a project-level list only suppresses prompts.
- Confirm the sandbox starts before relying on any of this. On Ubuntu 24.04+ every Bash command can fail with `apply-seccomp: write /proc/self/setgroups (nested userns is capability-restricted)`. Diagnosed and fixed on a live host: the sandbox needs a *nested* user namespace — bwrap makes the outer one, the vendored `apply-seccomp` makes an inner one to regain CAP_SYS_ADMIN — and AppArmor strips capabilities inside the first: with the `bwrap-userns-restrict` profile loaded, children run as `bwrap//&unpriv_bwrap` (`audit deny capability`); without it, the unconfined→`unprivileged_userns` transition does the same, which is why flipping `kernel.apparmor_restrict_unprivileged_userns` alone fixes nothing. Check with `bwrap --dev-bind / / -- cat /proc/self/attr/current`. The fix, printed for the human: unload and disable `bwrap-userns-restrict`, install in its place Ubuntu's standard per-application pattern — a `flags=(unconfined)` AppArmor profile for `/usr/bin/bwrap` containing `userns,` — and reload with `apparmor_parser -r`. Verified: `bwrap --unshare-all --dev-bind / / -- bwrap --unshare-user --dev-bind / / -- true` then succeeds and all seven probes pass. This restores pre-24.04 userns behaviour for bwrap only; the system-wide restriction stays on. Until the fix is applied it fails closed — a blocked agent, not an exposed one — and the user should use Pi.

### Codex cautions

- Codex confines writes and command execution, never reads: the docs describe `workspace-write` as "read files, edit within the workspace", and a probe under this config read a file from `$HOME`. No mode changes it — do not tell the user their other projects are protected under Codex.
- The beta permission-profile block (`default_permissions` plus `[permissions.<name>.filesystem]`) is the feature that would confine reads; on 0.148.0 it passes `--strict-config` and is then ignored, so the template omits it. Re-run `codex exec --strict-config` and the probes after each upgrade; if read confinement ships, adopt it and update the table above.
- Trust cuts both ways: project `.codex/` layers load only for a trusted project, yet trust by itself turns the sandbox off. The template resolves this by setting `sandbox_mode` explicitly, which overrides the trust default (verified by probe: writes outside a trusted repo stayed blocked). Check `~/.codex/config.toml` for a broad `[projects."..."] trust_level = "trusted"` entry covering the user's home — under one of those, every repo without an explicit `sandbox_mode` runs with no sandbox at all. Tell the user to remove it.

### Pi cautions

- The templates' schemas belong to the extensions, not Pi — verify keys against the pinned versions' READMEs before committing.
- Leave `deniedDomains` empty: it is the one hard block at the OS level, so a `"*"` there kills every request no matter what `allowedDomains` says.
- Do not promise open egress: on 0.6.5 the `network` section of a project-local `.pi/sandbox.json` had no effect at all — the built-in default allowlist governed (`registry.npmjs.org` 200, `example.com` blocked even when explicitly allowed). Fill `{{allowed-domains}}` from the stack anyway, then verify each domain the project needs with probe 4 and tell the user which ones resolved.
- `denyWrite` must keep `.pi`: pi-permission-system's project config *overrides* its global config (it is not tighten-only), so this hard write-block is what stops the agent loosening its own policy.
- `denyRead` blocks `/home` and `/Users` wholesale, which works because pi-sandbox prompts (rather than hard-fails) on reads outside `allowRead` — and in print mode the prompt times out to abort, so it fails closed.
- `allowAllUnixSockets` ships `false` — verified working (Bash runs, probes hold) once the host has the bwrap AppArmor fix from the Claude Code cautions. On a restricted host without that fix, `false` makes every Bash command fail with the same apply-seccomp/nested-userns error: apply the fix, or fall back to `true` (the container-control sockets stay blocked by path in `denyRead` either way). Whichever value you commit, confirm a Bash command still runs first.

## Prove that the sandbox holds

Run the probes through each configured agent CLI, non-interactively (`claude -p --permission-mode acceptEdits`, `codex exec`, `pi -p --approve`), and confirm the outcome from the host afterwards. Use a scratch repository with a decoy file in `$HOME`, never real secrets, and delete the artifacts after. A model that *declines* a probe proves nothing — the probe must fail at the sandbox or permission layer, with that error visible. Probes 1 and 2 are expected to FAIL under Codex (the known limit, not a repair job); everything else must pass for every configured agent:

1. Read a decoy file in `~` outside the project through the shell → denied.
2. The same read through the agent's native file-read tool → denied. This catches a missing `permissions` block — the check a Bash-only sandbox silently loses.
3. Write outside the repository (`touch ~/sandbox-escape-check`) → denied. Confirm from the host the file does not exist.
4. Fetch each domain the project needs, plus one it does not, and report which resolved. The configured list may not be the effective one — under Pi it was not — and an unattended run stalls on a domain that turns out to be blocked.
5. `sudo id` → denied. `git push --dry-run` → denied.
6. Append one character to the agent's own config (`.claude/settings.json`, `.codex/config.toml`, `.pi/sandbox.json`) through the shell and through the native edit tool → denied. Confirm `git diff` stays clean.
7. Normal work: read a project file, write and delete a scratch file in the repository, run the project's test command → all succeed.

A failed check is a finding: repair and re-run until each result is unambiguous. Report to the user a table of what each agent actually blocked — not a claim that the sandbox holds — and where a probe fails for a reason the agent cannot fix, say which agent to use instead.

## Hand over

Tell the user: start each agent exactly as usual — `claude`, `codex`, `pi` — in this repository; the sandbox rides along, no wrapper. Sandboxed Bash runs without prompts (Claude Code: `autoAllowBashIfSandboxed`; Codex: `approval_policy = "never"`), so sessions are already near-autonomous. For unattended runs give the exact commands — `claude -p --permission-mode acceptEdits`, `codex exec`, `pi -p --approve` — repeat the enforcement table, name the agent whose probes actually passed, and repeat that the bypass flags undo this setup. The lasting rules: no secrets in the repository the user cannot lose; the developer pushes from their own shell after review; review `git diff -- .claude/ .codex/ .pi/` before each session; a repository without this config has no protection — run the skill there first.

A project that genuinely needs `sudo`, system services, or native Windows is outside what this sandbox can hold. Use a disposable container or VM there — the container variant of this skill lives in this repository's git history.

---
name: set-up-sandbox
description: Sets a project up with native, project-local sandboxing for coding agents — Claude Code, Codex, and Pi run directly against the repository, with the OS enforcing the boundary. No container, no image build. Produces committed config under .claude/, .codex/, and .pi/. The developer then starts the agent CLIs exactly as usual.
disable-model-invocation: true
---

# Set Up Sandbox

Give the current repository project-local, OS-enforced sandboxing for coding agents. The developer runs the same agent CLIs as always, directly against the project — no container, no separate image to build or keep current. Each agent's own sandbox carries the policy: `.claude/settings.json` for Claude Code, `.codex/config.toml` plus `.codex/rules/` for Codex, and for Pi the `pi-sandbox` plus `@gotgenes/pi-permission-system` extensions, configured under `.pi/`. The config is committed, so the repository itself defines the policy.

The security model. Each step preserves it:

> Anything inside the repository may be destroyed or leaked. Everything outside the repository must be unreachable — enforced at the OS or sandbox layer, below the model.

That is the goal. Only Pi currently reaches all of it. What each agent actually enforces, verified by running the probes below on Linux against Claude Code 2.1.238, codex-cli 0.148.0, and pi-sandbox 0.6.5 on 2026-08-20:

| Agent | Reads outside the repo | Writes outside the repo | Notes |
| --- | --- | --- | --- |
| Pi | blocked | blocked | Shell and native tools both. The one that meets the model in full |
| Codex | **allowed** | blocked | No sandbox mode confines reads; this is by design, not a misconfiguration |
| Claude Code | untested here | untested here | Its sandbox failed to start on the test host; see the caution below |

Never present this as three equivalent options. If the user's goal is keeping the agent out of their other projects, say plainly that Codex cannot do it and Pi can.

There are three layers, strongest first: the OS filesystem and network sandbox, command deny rules, model instructions. The first is the boundary. The second is policy on top. The third is not a security layer at all. Egress is open by default where the agent honours the setting — Claude Code and Codex do, Pi's project-local network config did not — so tell the user two consequences plainly: secrets that they cannot afford to leak do not belong in the repository (the deny globs for `.env` and key files raise the bar, they are not the boundary); and a prompt injection carried in a page the agent reads can send repository contents anywhere. An allowlist does not fix the second one — it is porous wherever it admits a code host, since an agent that may reach `github.com` can push data to any repository on it. The filesystem boundary is what keeps everything else out of reach, and it is unaffected by the open network.

## Invariants

A problem that you find never makes it valid to break one of these:

- Fail closed. Claude Code: `failIfUnavailable: true` and `allowUnsandboxedCommands: false`. Codex: an explicit `sandbox_mode`. Pi: hard denies, no ask-to-escape. A sandbox that cannot start must stop the agent, not wave it through.
- Never generate config that only looks like a boundary. If a key is accepted and then ignored by the shipped CLI, leave it out and say so in a comment. Test the claim before you write it down: run the probes, and describe what they returned, not what the documentation promises.
- Cover the native file tools, not only Bash. Claude Code's Read/Edit/Write tools bypass the Bash sandbox; only the `permissions.deny` rules cover them. Never generate the `sandbox` block without its `permissions` block.
- The agent must not be able to edit its own policy. Sandboxed Bash is OS-blocked from `.claude/` config files; the deny rules close the native-tool path. The lasting rule for the user: review `git diff -- .claude/ .codex/ .pi/` before each session.
- Never generate or recommend the bypass flags. `--dangerously-skip-permissions` auto-approves everything the deny rules do not name; `--dangerously-bypass-approvals-and-sandbox` turns the Codex sandbox off entirely.
- Print privileged installations (`bubblewrap`, `socat`) for the human to run. Then verify them. Never run them yourself. The Pi extensions are third-party code inside the trust boundary: pin their versions, and point the user at their sources (`pi-sandbox` delegates its OS layer to a fork of Anthropic's `sandbox-runtime`) before they install.

## The conversation

Detect the OS and the installed agent CLIs. Inspect the repository for its stack. Then settle three items with the user, in conversation. Give a recommendation for each item:

1. **Platform** — macOS needs nothing. Linux and WSL2 need `bubblewrap` and `socat` (Claude Code) and `bwrap` (Codex, Pi extension); print the install command for the human. Windows outside WSL2: stop, and get the user into WSL2 first.
2. **Agents** — which of Claude Code, Codex, and Pi this project uses. Generate config only for those, and give the user the enforcement table above before they choose. For Pi, the sandbox is two extensions — core Pi has none, and project trust is not a sandbox. `pi-sandbox` is the OS boundary (bubblewrap/Seatbelt plus a filtering network proxy, and it intercepts Pi's native read/write/edit tools); `@gotgenes/pi-permission-system` is the hard-deny policy layer on top (its denies never prompt, and it parses compound commands). Install both project-locally, pinned: `pi install -l npm:pi-sandbox@<version>` and `pi install -l npm:@gotgenes/pi-permission-system@<version>` — this records them in `.pi/settings.json`, which gets committed too.
3. **Policy** — the command denies: `sudo`, `su`, `doas`, `ssh`, `scp`, `git push`, and the deploy verbs are the default; whether `aws`, `gcloud`, or `kubectl` are denied outright depends on the project — ask.

If agent sandbox config already exists, this is an update. Ask what the user wants changed. Repair the existing setup. Do not recreate it.

## Generate

Fill the templates for the selected agents, resolve the deny lists from the settled policy, and commit:

| Agent       | Destination                                        | Template                                                                        |
| ----------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| Claude Code | `.claude/settings.json`                            | [claude-settings.json](assets/templates/claude-settings.json)                   |
| Codex       | `.codex/config.toml`, `.codex/rules/security.rules` | [codex-config.toml](assets/templates/codex-config.toml), [codex-security.rules](assets/templates/codex-security.rules) |
| Pi          | `.pi/sandbox.json`, `.pi/extensions/pi-permission-system/config.json` | [pi-sandbox.json](assets/templates/pi-sandbox.json), [pi-permission-system.json](assets/templates/pi-permission-system.json) |

Three cautions while filling:

- Claude Code: `allowRead: ["."]` resolves against the project root only because the file lives in `.claude/settings.json` — never move this block to user-level settings. Broad home rules (`Read(~/**)`) do not belong in `permissions.deny`: deny beats allow, and a project under `~` would lock itself out. Deny the sensitive directories by name, as the template does. The single `WebFetch(domain:*)` allow rule is what opens egress, and it does double duty: `WebFetch` allow rules also pre-allow domains for the sandbox proxy, so it covers `curl` and `npm install` as well as the fetch tool. It needs the workspace trust dialog before it applies. Before relying on any of it, confirm the sandbox starts: on some Linux hosts it fails with `apply-seccomp: write /proc/self/setgroups (nested userns is capability-restricted)` and no Bash command runs at all, because Claude Code's sandbox needs a nested user namespace and the host allows only one level (`bwrap --unshare-all -- bwrap --unshare-user` reproduces it directly). Installing `@anthropic-ai/sandbox-runtime` does not fix it, and neither does clearing AppArmor's `apparmor_restrict_unprivileged_userns`. It fails closed, so the risk is a blocked agent rather than an exposed one — but on such a host Claude Code has no working sandbox, and the user should be told to use Pi and to file the bug rather than left to discover it mid-loop. To tighten later, drop that rule and add a `sandbox.network.allowedDomains` list — but know what that buys: `strictAllowlist` is the setting that turns a miss into a block, and it is ignored in project settings, so a project-level list only suppresses prompts.
- Codex: Codex confines writes and command execution, never reads. The docs describe `workspace-write` as "read files, edit within the workspace", and a probe under this config read a file from `$HOME`. There is no mode that changes this, so do not tell the user their other projects are protected under Codex — they are not. The beta permission-profile block (`default_permissions` plus `[permissions.<name>.filesystem]`) is the feature that would have confined reads; on 0.148.0 it passes `--strict-config` and is then ignored, so the template does not generate it. Two things decide whether the config applies at all, and they pull against each other: project `.codex/` layers load only for a trusted project, and trust by itself turns the sandbox off. The template resolves this by setting `sandbox_mode` explicitly, which overrides the trust default — verified by probe, writes outside the repo stayed blocked in a trusted project. So check `~/.codex/config.toml` for a broad `[projects."..."] trust_level = "trusted"` entry covering the user's whole home directory: with one of those and no explicit `sandbox_mode`, every repository underneath runs with no sandbox at all. Tell the user to remove it. Re-run `codex exec --strict-config` and the probes after each Codex upgrade; if a released permission profile gains read confinement, adopt it and update the table above.

- Pi: the templates' schemas belong to the extensions, not to Pi — verify keys against the READMEs of the pinned versions before committing. Three behaviors that the templates already encode, and that must survive any edit: leave `deniedDomains` empty — `deniedDomains` is the one hard-block at the OS level, so a `"*"` there blocks every request no matter what `allowedDomains` says. Do not promise open egress for Pi: on 0.6.5 the `network` section of a project-local `.pi/sandbox.json` did not take effect at all, and pi-sandbox's built-in default allowlist governed instead — `registry.npmjs.org` returned 200 while `example.com` failed with `CONNECT tunnel failed, 502`, and an explicit `allowedDomains: ["example.com"]` did not change that. Fill `{{allowed-domains}}` from the stack anyway, then verify each domain the project actually needs with probe 4 and tell the user which ones resolved; `denyWrite` must keep `.pi` — pi-permission-system's project config overrides its global config (it is not tighten-only), so this hard write-block is what stops the agent from loosening its own policy; and `denyRead` blocks `/home` and `/Users` wholesale, which works because pi-sandbox prompts (rather than hard-fails) on reads outside `allowRead` — and in print mode that prompt times out to abort, so it fails closed. One deliberate loosening sits alongside those three: `allowAllUnixSockets` ships `true`, because on Linux hosts with AppArmor's `apparmor_restrict_unprivileged_userns=1` (Ubuntu 24.04+) the `false` setting makes every Bash command fail with an `apply-seccomp`/nested-userns error. That failure is closed, not open, but it is indistinguishable from a broken install, so the template takes the working default and blocks the sockets that matter — the container-control sockets in `denyRead` — by path instead. On a host without that AppArmor restriction, tightening it back to `false` is a real improvement; confirm a Bash command still runs before you commit it.

## Prove that the sandbox holds

Run the probes through each configured agent CLI, non-interactively (`claude -p --permission-mode acceptEdits`, `codex exec`, `pi -p --approve`), and confirm the outcome from the host afterwards. Run them in a scratch repository with a decoy file in `$HOME`, never against real secrets, and delete the artifacts afterwards. Probes 1 and 2 are expected to FAIL under Codex; that is the known limit above, not a repair job. Every other probe must pass for every configured agent. A model that declines a probe proves nothing — the probe must fail at the sandbox or permission layer, with that error visible. Re-run until each result is unambiguous:

1. Read a decoy file in `~` outside the project through the shell → denied (expected: Pi passes, Codex fails by design).
2. The same read through the agent's native file-read tool → denied. This is the check that catches a missing `permissions` block, and the one that a Bash-only sandbox silently loses.
3. Write outside the repository (`touch ~/sandbox-escape-check`) → denied. Confirm on the host that the file does not exist.
4. Fetch each domain the project needs, plus one it does not, and report which resolved. Do not assume the configured list is the effective one — under Pi it was not. An unattended run stalls on a domain that turns out to be blocked.
5. `sudo id` → denied. `git push --dry-run` → denied.
6. Append one character to the agent's own config (`.claude/settings.json`, `.codex/config.toml`, `.pi/sandbox.json`) through the shell and through the native edit tool → denied. Confirm `git diff` stays clean.
7. Normal work: read a project file, write a scratch file in the repository, run the project's test command, delete the scratch file → all succeed.

A failed check is a finding. Repair, and test again. Report the results to the user as a table of what each agent actually blocked — not a claim that the sandbox holds. Where a probe fails for a reason the agent cannot fix, say which agent to use instead.

## Hand over

Tell the user: start each agent exactly as usual — `claude`, `codex`, `pi` — in this repository. The sandbox rides along; there is no wrapper script and nothing to enter. Sandboxed Bash runs without prompts (Claude Code: `autoAllowBashIfSandboxed`; Codex: `approval_policy = "never"`), so sessions are already near-autonomous. Repeat the enforcement table in the handover: for an unattended loop, name the agent whose probes actually passed. For unattended runs, give the exact commands: Claude Code `claude -p --permission-mode acceptEdits`, Codex `codex exec`, Pi `pi -p --approve` — and repeat that the bypass flags are never the answer here; they undo this setup. The lasting rules: no secrets in the repository that the user cannot lose; the developer pushes, from their own shell, after review; review `git diff -- .claude/ .codex/ .pi/` before each session; and a repository without this config has no protection — run the skill there before running an agent.

A project that genuinely needs `sudo`, system services, or native Windows is outside what this sandbox can hold. Use a disposable container or VM for that project — the container variant of this skill lives in this repository's git history.

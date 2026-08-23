---
name: set-up-sandbox
description: Sets a project up with native, project-local sandboxing for coding agents — Claude Code, Codex, and Pi run directly against the repository, with the OS enforcing the boundary. No container, no image build. Produces committed config under .claude/, .codex/, and .pi/. The developer then starts the agent CLIs exactly as usual.
disable-model-invocation: true
---

# Set Up Sandbox

Give the current repository OS-enforced sandboxing for coding agents — no container, no wrapper. Each agent's own sandbox carries the policy, committed in the repo: `.claude/settings.json` for Claude Code, `.codex/config.toml` plus `.codex/rules/` for Codex, and `.pi/sandbox.json` plus `.pi/extensions/pi-permission-system/config.json` for Pi. The developer starts the CLIs exactly as usual.

The security model, which every step must preserve:

> Anything inside the repository may be destroyed or leaked. Everything outside the repository must be unreachable — enforced at the OS or sandbox layer, below the model.

What each agent actually enforces — measured on Linux against Claude Code 2.1.238, codex-cli 0.148.0, and pi-sandbox 0.6.5 (2026-08-20), not taken from docs:

| Agent | Reads outside the repo | Writes outside the repo | Notes |
| --- | --- | --- | --- |
| Pi | blocked | blocked | Shell and native tools both — the one that meets the model in full |
| Codex | **allowed** | blocked | No sandbox mode confines reads; by design, not a misconfiguration |
| Claude Code | blocked | blocked | Shell blocked by the OS (bwrap masks `$HOME`); native tools covered by deny rules. Needs the AppArmor fix on Ubuntu 24.04+ (cautions) — without it no Bash command runs at all |

Three layers, strongest first: the OS sandbox (the boundary), command deny rules (policy on top), model instructions (not a security layer). Egress is open where the agent honours the setting. Tell the user the two consequences plainly: secrets they cannot afford to leak do not belong in the repository (the `.env`/key denies raise the bar, they are not the boundary), and a prompt injection in a page an agent reads can send repository contents anywhere.

## Invariants

No problem you hit makes it valid to break one of these:

- Fail closed. Claude Code: `failIfUnavailable: true`, `allowUnsandboxedCommands: false`. Codex: an explicit `sandbox_mode`. Pi: hard denies, no ask-to-escape. A sandbox that cannot start must stop the agent, not wave it through.
- Never write config that only looks like a boundary. If the CLI accepts a key and then ignores it, leave the key out and say so in a comment. Trust what was measured, not what the docs promise.
- Cover the native file tools, not only Bash. Claude Code's Read/Edit/Write bypass the Bash sandbox; only `permissions.deny` covers them. Never generate the `sandbox` block without its `permissions` block.
- No agent may edit its own policy — or another agent's. Deny rules and read-only mounts close that path for Claude Code and Pi; for Codex, only the user's review does (cautions). Lasting rule for the user either way: review `git diff -- .claude/ .codex/ .pi/` before each session.
- Never generate or recommend the bypass flags. `--dangerously-skip-permissions` auto-approves everything the deny rules do not name; `--dangerously-bypass-approvals-and-sandbox` turns the Codex sandbox off entirely.
- Print privileged commands (`bubblewrap`/`socat` installs, AppArmor changes) for the human to run, then verify them; never run them yourself. The Pi extensions are third-party code inside the trust boundary: pin their versions and point the user at their sources (`pi-sandbox` delegates its OS layer to a fork of Anthropic's `sandbox-runtime`) before they install.

## The conversation

Detect the OS and installed agent CLIs, inspect the repository's stack, then settle six items with the user, recommending a default for each:

1. **Platform** — macOS needs nothing. Linux and WSL2 need `bubblewrap` and `socat`; print the install command. Ubuntu 24.04+ also needs the AppArmor bwrap fix (cautions), or no Claude Code Bash command runs at all. Windows outside WSL2: stop, and get the user into WSL2 first.
2. **Agents** — which of the three this project uses. Generate config only for those, and show the enforcement table before they choose. Pi's sandbox is two extensions — core Pi has none, and project trust is not a sandbox: `pi-sandbox` is the OS boundary (bubblewrap/Seatbelt plus a filtering network proxy; it also intercepts Pi's native file tools), `@gotgenes/pi-permission-system` the hard-deny policy layer (its denies never prompt, and it parses compound commands). One pinned global install per machine serves every project — `pi install npm:pi-sandbox@<version>` and `pi install npm:@gotgenes/pi-permission-system@<version>` — since the policy files stay per-repo either way. Pin is the security control, not locality: an unpinned entry silently auto-upgrades, and upgrades have changed enforcement semantics before. Check `~/.pi/agent/settings.json` for existing unpinned entries and have the user pin them. Use project-local installs (`pi install -l`) only when the user wants the repo self-contained — then every clone must re-run them before Pi has any sandbox. This repo's [package.json](package.json) mirrors the pinned versions so Dependabot flags new releases; a release PR means review-and-re-verify, never auto-merge.
3. **Command denies** — `sudo`, `su`, `doas`, `pkexec`, `ssh`, `scp`, `git push` are the default. Deploy tools (`terraform`, `kubectl`, `aws`, `gcloud`) get denies only when installed on the host — ask which.
4. **Personal directories** — the template denies, by name, credential stores and files that run code later (shell rc files), plus the author's personal directories `~/Main` and `~/Temporary` — another user replaces those to taste. Ask which other directories should be unreadable and unwritable by the agents' file tools and add named `Read`/`Edit` denies for each. Never a bare `Read(~/**)`, and never `~/.*` dotfile globs — see the cautions. The agents' own global directories are readable by default (see "Agent globals" below) — mention it, and close them for a user who wants full masking. Sibling projects deserve an explicit word: the `$HOME` tmpfs mask confines Bash only — Claude Code's native Read/Grep/Glob reach anything under `~` that no deny names, including the user's other repos and their secrets. A bare deny of the code root (e.g. `Read(~/Code/**)`) is self-lockout — the current repo lives under it, deny beats allow, and deny rules carry no exceptions. The durable middle, in the template: secret-file globs under the code root (`Read(~/Code/**/.env*)`, `*.pem`, `*.key`) — adjust the root to the host. Offer named per-sibling denies for full isolation, saying plainly that the list goes stale with every new project and that Codex reads siblings regardless.
5. **Container sockets** — when docker/podman are installed and the user is in the `docker` group, the socket is a decision, not a default: an agent that reaches it can `docker run -v /:/host` and get root on the host — a complete escape from every layer here. If the project's workflow runs on containers, present that trade-off and let the user choose. Allowed: drop the socket-path denies, set Pi's `allowAllUnixSockets: true`, and record the choice in a dated config comment so it reads as a decision, not an oversight. Denied: add `Bash(docker:*)`/`Bash(podman:*)` denies and keep the socket paths in Pi's `denyRead`.
6. **Unix sockets** — Claude Code and pi-sandbox block `socket(AF_UNIX)` through the same optional seccomp filter, and on Linux it is all-or-nothing: the per-path allowlists (`network.allowUnixSockets`, pi-sandbox's `allowUnixSockets`) are macOS-only and silently ignored, because seccomp cannot see paths. Grep the sources *and tests* for `AF_UNIX`, `socketpair`, `sun_path`, or local-socket IPC — if the project creates any, its own checks will fail with `Operation not permitted` under the default. Present the choice and apply it to both agents at once: allow (`sandbox.network.allowAllUnixSockets: true` for Claude Code, `allowAllUnixSockets: true` for Pi) or keep blocked. Allowing does not open the container sockets from item 5 — those stay behind the path denies, the command denies, and write confinement on `/run`.

If sandbox config already exists, this is an update: ask what the user wants changed and repair it, don't recreate it.

## Generate

### Write order

Your own agent's config takes effect the moment it lands: the running session re-initializes its sandbox, the three policy directories become read-only to the shell, and the new deny rules close the native-tool path — you are locked out of finishing. So do everything that needs an unsandboxed view first — the `$HOME` probes, toolchain resolution, Pi schema verification, any `pi install` — then write the other agents' files, and your own agent's config **last**. If a lockout happens anyway: stage the remaining files in a directory at the repo root (the root stays writable) and hand the user one copy command for a separate terminal — never the `!` prefix, which runs inside the session's sandbox and fails the same way. Verification is impossible from the generating session (the agent CLIs themselves live under the masked `$HOME`); it belongs to fresh sessions, after handover. A transient `apply-seccomp: unshare(CLONE_NEWUSER): Invalid argument` fails closed — retry once, and never diagnose host state from inside the sandbox.

### Templates

Fill the templates for the selected agents. The `~`-path deny list is a superset — trim it against the host while `$HOME` is still readable: always keep the universal core (`~/.ssh`, `~/.gnupg`, `~/.claude.json`, the credential/session denies inside the agent globals ("Agent globals" below), all the `Edit(~/.claude/**)`-style write denies, `~/.netrc`, `~/.npmrc`, the rc-file rules, the personal directories); keep tool-specific entries (`~/.aws`, `~/.kube`, `~/.docker`, `~/.config/gh`, `~/.config/gcloud`, `~/.local/share/keyrings`, `~/.pgpass`) only when the path exists. A deny for a missing path protects nothing; note in the handover that installing such a tool later means re-running the skill.

| Agent       | Destination                                        | Template                                                                        |
| ----------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| Claude Code | `.claude/settings.json`                            | [claude-settings.json](assets/templates/claude-settings.json)                   |
| Codex       | `.codex/config.toml`, `.codex/rules/security.rules` | [codex-config.toml](assets/templates/codex-config.toml), [codex-security.rules](assets/templates/codex-security.rules) |
| Pi          | `.pi/sandbox.json`, `.pi/extensions/pi-permission-system/config.json` | [pi-sandbox.json](assets/templates/pi-sandbox.json), [pi-permission-system.json](assets/templates/pi-permission-system.json) |

### Read-only carve-ins

The Claude Code and Pi templates re-allow a few paths inside the masked `$HOME` so ordinary tooling works — `~/.gitconfig` (commit identity), toolchain and cache directories. More-specific paths win over the broad deny, so carve-ins don't weaken it. Never carve in credential stores; the agent globals are the one deliberate exception, below.

Find the real list by probing, not from the template: `command -v` every binary the project's documented checks invoke — runners often live in unlisted places (measured examples: `~/.vite-plus`, `~/go/bin`, `~/.local/share/uv`, plus that tool's config dir) — and the package-manager store paths (`pnpm store path`). A missed carve-in only shows up as "command not found" at first use, so run the project's check commands under the finished config before handover.

### Agent globals: readable, never writable

The templates carve the agents' global directories — `~/.claude`, `~/.codex`, `~/.pi` — into the readable set. This is a deliberate, bounded exception to full `$HOME` masking: fully masking them makes sessions fail in confusing ways (Claude Code spills oversized tool output to `~/.claude/projects/<project>/` and then can't read it back — the symptom is `No such file or directory` for a file the agent watched itself write), and the residual exposure is OAuth tokens, which the user accepted as revocable (log out, log back in). Three things stay denied *inside* the globals, at both the OS layer and the native-tool rules:

- **Credential files** — `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.pi/agent/auth.json` (plus `~/.claude.json`, which holds cross-project prompt history). No workflow reads them, so the denies cost nothing.
- **Other projects' transcripts** — `~/.claude/projects`, `~/.codex/sessions`, `~/.pi/agent/sessions`. Transcripts contain the contents of *other* repositories; opening them would break per-repo containment through a side door. Carve the current project's own Claude transcript directory back in: its name is the repo's absolute path with `/` replaced by `-` (e.g. `-home-stefan-Code-personal-duet-daw`) — confirm against `ls ~/.claude/projects` while `$HOME` is still readable, and replace the template's `<this-projects-transcript-dir>` placeholder.
- **All writes** — every write deny stays, and there are never write carve-ins here. These directories are where the sandboxes themselves come from (`~/.pi/agent` *is* the enforcement code); a writable global is a full escape-and-persistence channel, not a token-loss risk.

The nesting (deny inside allow inside deny) relies on more-specific-path-wins. Allow-inside-deny is measured (Claude Code 2.1.241); the deny-inside-allow level must be part of the fresh-session checks: a read of another project's transcript and of a credential file must fail under Claude Code and Pi.

### Repo-local package caches

Carve-ins are read-only, and package managers must write their caches — measured: pnpm 11 fails even with a warm store (`ERR_SQLITE_ERROR` — it opens the store index read-write at startup), uv fails on its cache lock, npm on `_cacache/tmp`. Do not fix this by making home-directory caches writable: they are shared with every other project and the user's own shell, so a writable shared cache is an escape-and-persistence channel through the boundary. Instead, move each cache into the repository — the one place everything may write — via the package manager's own committed config, which works identically under all three agents, CI, and fresh clones:

- pnpm 11: `storeDir: .pnpm-store` and `cacheDir: .pnpm-cache` in `pnpm-workspace.yaml` — **not** `.npmrc` `store-dir`, which pnpm 11 silently ignores; verify with `pnpm store path`
- npm: `cache=.npm-cache` in a repo `.npmrc`
- uv: `cache-dir = ".uv-cache"` under `[tool.uv]` in `pyproject.toml` (resolves against the working directory, so subdirectory runs may each get a cache — harmless)
- ccache: repo-local `CCACHE_DIR`, e.g. via a CMake preset `environment` block (build presets inherit the configure preset's environment)

Gitignore the cache directories and drop the now-useless store-path carve-ins. Tell the user the one trade-off: their own shell in this repo also uses the repo-local store, so the first install re-downloads instead of hitting the global cache.

### Claude Code cautions

- `allowRead: ["."]` resolves against the project root only because the file lives in `.claude/settings.json` — never move the block to user-level settings. No broad `Read(~/**)` denies (deny beats allow — a project under `~` would lock itself out), and no `~/.*` dotfile globs (measured on 2.1.238: they crash every Bash call at spawn; fail-closed). The deny list is names, not globs; top-level files like `~/.claude.json` need their own entries. Non-hidden, non-named directories under `~` stay reachable by the native tools — and in auto modes those reads go through without a prompt (measured: a sibling project's file read cleanly on 2.1.241). That residue is the price of living under `~`; the secret globs from conversation item 4 trim its sharpest edge.
- File denies must be spelled `Edit(path)` — Claude Code does not match `Write(path)` rules (Edit rules cover all file-editing tools). `Read(path)` rules match normally.
- The single `WebFetch(domain:*)` allow rule opens egress and does double duty: allow rules also pre-allow domains for the sandbox proxy, covering `curl` and `npm install`. It only applies after the workspace trust dialog — headless hosts need `hasTrustDialogAccepted: true` in `~/.claude.json`. To tighten later, drop it and set `sandbox.network.allowedDomains` — knowing `strictAllowlist` is ignored in project settings.
- Ubuntu 24.04+ AppArmor trap: every Bash command can fail with an apply-seccomp / nested-userns error, because AppArmor strips capabilities inside bwrap's user namespace. Check with `bwrap --dev-bind / / -- cat /proc/self/attr/current` (want `unconfined`). The fix, printed for the human: unload and disable the `bwrap-userns-restrict` profile, install a `flags=(unconfined)` AppArmor profile for `/usr/bin/bwrap` containing `userns,`, reload with `apparmor_parser -r`. Verify: `bwrap --unshare-all --dev-bind / / -- bwrap --unshare-user --dev-bind / / -- true` succeeds. This restores userns for bwrap only; the system-wide restriction stays on. Until fixed it fails closed — a blocked agent, not an exposed one.
- Self-policy, measured on 2.1.238: a live sandbox mounts all three policy directories read-only to the shell. A session started before the config existed does not have that mount, so keep the `Edit(.claude/**)`/`Edit(.codex/**)`/`Edit(.pi/**)` denies — and re-check the mounts after upgrades rather than relying on them.
- Deny beats allow with no way back: `Read(.env.*)` also hides a committed `.env.example` the project may tell agents to read. Where one exists, name the real variants (`.env.local`, ...) instead of the blanket glob. (Pi differs: there a later, more-specific allow wins, so `*.env.example: allow` after the deny works.)
- Rc-file denies must survive symlinks: `~/.zshrc → ~/dotfiles/zsh/.zshrc` makes the deny bypassable through its target. `ls -la` the rc files and deny the target directory (e.g. `Edit(~/dotfiles/**)`) when they are links.
- When the optional seccomp filter (`@anthropic-ai/sandbox-runtime`) is installed, sandboxed shells cannot create `AF_UNIX` sockets — project code and tests die with `Operation not permitted` (measured on 2.1.241). `sandbox.network.allowAllUnixSockets: true` is the only Linux control; see conversation item 6.
- The `$HOME` mask reports denials as `No such file or directory` (ENOENT), not permission errors — the sandboxed `$HOME` is a tmpfs, so denied paths simply don't exist there. Writes into it can even appear to succeed and then evaporate. Say so in the handover, or verification reads look like missing files and containment looks like a bug.

### Codex cautions

- Codex confines writes and command execution, never reads — a probe under this config read a file from `$HOME`, and no mode changes it. Do not tell the user their other projects are protected under Codex.
- The beta permission-profile block that would confine reads passes `--strict-config` on 0.148.0 and is then ignored, so the template omits it. Re-check after each upgrade; adopt it if read confinement ships, and update the table above.
- Trust cuts both ways: project `.codex/` config loads only for a trusted project, yet trust alone turns the sandbox off. The template sets `sandbox_mode` explicitly, which overrides the trust default (verified). Check `~/.codex/config.toml` for a broad `trust_level = "trusted"` entry covering the user's home — under one, every repo without an explicit `sandbox_mode` has no sandbox at all. Tell the user to remove it.
- The rules DSL is command-prefix only — no path rules — and `workspace-write` leaves the whole repo writable, policy directories included. Under Codex, only the `git diff` review rule guards `.claude/`, `.codex/`, and `.pi/`. Say so, rather than implying the self-policy invariant holds for all three agents.

### Pi cautions

- The templates' schemas belong to the extensions, not Pi — verify every key against the pinned versions (`npm pack` the tarballs, read the README and the shipped JSON schema) *before* your own agent's config lands, while npm is still reachable. That includes confirming the pinned pi-sandbox expands `~` in `allowRead`.
- Glob syntax, measured on pi-permission-system 26.3.1: `**` is not a token — it behaves as a plain `*`, which already crosses path separators, so `**/.env` silently under-matches. Write `*.env` (a leading `*` matches zero characters). Relative patterns also match in cwd-absolute form but not the reverse — pair `.pi/*` with a `*/.pi/*` twin. Ordering is last-match-wins: the `*.env.example` allow goes after the `*.env.*` deny. Validate the finished config against the package's shipped schema (`additionalProperties: false` — an unknown key is a rejected config, and a wrong pattern is a boundary that only looks like one).
- Project trust gates everything: pi-permission-system loads project config only for a project trusted in `~/.pi/agent/trust.json` — untrusted means the entire `.pi/` policy is silently skipped. Tell the user to accept the trust prompt on first run and confirm with `/sandbox`, watching for a `project_trust.skipped` warning.
- A global `~/.pi/agent/sandbox.json` merges its path and domain arrays with the project's — it can silently widen the policy. Check it before writing the project file.
- pi-sandbox refuses to initialize without ripgrep (`rg`) on PATH.
- Generate no `allowedDomains`/`deniedDomains`: on 0.6.5 the project-local domain keys are silently ignored — the built-in allowlist governs. Don't promise open egress; tell the user to test which domains the project needs before an unattended run stalls on one. If an upgrade honours them, adopt them then — and never `"*"` in `deniedDomains`, which blocks every request.
- `denyRead` blocks `/home` and `/Users` wholesale — safe because pi-sandbox prompts on reads outside `allowRead`, and in print mode the prompt times out to abort (fails closed). The explicit `~/Main`/`~/Temporary` entries are redundant under it, kept so the intent survives if the wholesale deny is ever loosened.
- `denyWrite` must keep `.pi`, `.claude`, and `.codex`: project config *overrides* global config (it is not tighten-only), so this hard write-block is what stops the agent loosening its own — or another agent's — policy.
- `allowAllUnixSockets: false` requires the AppArmor fix above; without it every Bash command fails with the nested-userns error. Apply the fix, or fall back to `true` (the container sockets stay blocked by path in `denyRead`). Either way, confirm a Bash command runs.
- `external_directory: "deny"` never prompts and can block Pi from reading its own install (e.g. under `~/.nvm`); carve that in with the top-level `piInfrastructureReadPaths` key if Pi fails to start.
- With project-local extension installs, `.pi/npm/` self-ignores via its own `.gitignore` — a fresh clone gets the policy but no extensions, and Pi without them has no sandbox. The handover must say: re-run the `pi install -l` commands after cloning. (Global installs avoid this; a new machine needs the global install once.)
- pi-sandbox 0.6.5 injects `TMPDIR=/tmp/claude` into sandboxed shells but never creates the directory — inherited from its `sandbox-runtime` ancestry (Claude Code itself moved to `/tmp/claude-<uid>` and creates it). Anything using the system temp dir (`temp_directory_path()`, `mkstemp`, Python `tempfile`) dies instantly, and the error misleadingly names a Claude path inside a Pi session. Print the durable fix for the human, once per machine: `echo 'd /tmp/claude 0700 <user> <user> -' | sudo tee /etc/tmpfiles.d/pi-sandbox.conf && sudo systemd-tmpfiles --create` (survives reboots and periodic /tmp cleanup; a bare `mkdir -p /tmp/claude` does not). Re-check whether the injection is fixed on every version bump.

## Hand over

Tell the user: start each agent exactly as usual — `claude`, `codex`, `pi` — in this repository; the sandbox rides along, no wrapper. Verification happens in *fresh* sessions — each agent reads its config at startup, and the generating session cannot test it from inside. Name the standing blind spot: `.claude/settings.local.json` is untracked and silently overrides project settings — `git diff` never shows it.

Give the user a paste-ready verification prompt, one per agent, near-identical so results compare across the three. First, from a normal terminal: `echo "DECOY-$RANDOM" > ~/sandbox-decoy.txt`. Then, filling in the project's own check command and swapping the policy file per agent (`.claude/settings.json` / `.codex/config.toml` / `.pi/sandbox.json`):

> Run these checks in order and report each as SUCCEEDED or BLOCKED with the exact error. Do not work around anything that fails — a failure may be the correct result. 1. Read `~/sandbox-decoy.txt` and tell me its contents. 2. Create `~/sandbox-escape.txt` containing ESCAPED. 3. Add a blank line to the end of <own policy file>. 4. Run `sudo -n true`, then `docker ps`. 5. Read a file inside another project's directory under `~/.claude/projects/`, and read `~/.claude/.credentials.json`. 6. Run <the project's check command>. Change nothing else.

Expected: everything blocked and the checks green — except Codex, whose decoy read succeeds (no read confinement) and whose policy-file edit is refused only by instructions, not enforcement; say both plainly. Under Claude Code, denied reads report `No such file or directory` (the tmpfs mask), and the escape write may "succeed" into the ephemeral tmpfs — have the user confirm from a normal terminal that `~/sandbox-escape.txt` does not exist, then delete the decoy. Check 5 is what proves the deny-inside-allow nesting from "Agent globals". A Claude Code session dying on `apply-seccomp` means the sandbox didn't start — fail-closed, not exposure. Under Pi, accept the trust prompt and check `/sandbox` for `project_trust.skipped`.

Also warn about a cosmetic scare: under a live Claude Code sandbox, `git status` shows `.bashrc`, `.zshrc`, `.gitconfig` and friends as untracked at the repo root. They are `/dev/null` bind mounts the sandbox creates to neutralise code-executing config — namespace-only, char devices, not on disk; a normal terminal shows nothing. Don't gitignore them.

Sandboxed Bash runs without prompts (Claude Code: `autoAllowBashIfSandboxed`; Codex: `approval_policy = "never"`), so sessions are already near-autonomous. For unattended runs give the exact commands — `claude -p --permission-mode acceptEdits`, `codex exec`, `pi -p --approve` — and repeat the enforcement table and that the bypass flags undo this setup. The lasting rules: no secrets in the repository the user cannot lose; the developer pushes from their own shell after review; review `git diff -- .claude/ .codex/ .pi/` before each session; a repository without this config has no protection — run the skill there first.

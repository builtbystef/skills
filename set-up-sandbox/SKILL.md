---
name: set-up-sandbox
description: Sets a project up with native, project-local sandboxing for coding agents — Claude Code, Codex, and Pi run directly against the repository, with the OS enforcing the boundary. No container, no image build. Produces committed config under .claude/, .codex/, and .pi/. The developer then starts the agent CLIs exactly as usual.
disable-model-invocation: true
---

# Set Up Sandbox

Give the current repository OS-enforced sandboxing for coding agents — no container, no wrapper. Each agent's own sandbox carries the policy, committed in the repo: `.claude/settings.json` for Claude Code, `.codex/config.toml` plus `.codex/rules/` for Codex, and `.pi/sandbox.json` plus `.pi/extensions/pi-permission-system/config.json` for Pi. The developer starts the CLIs exactly as usual.

The security model, which every step must preserve:

> Writes are confined to the repository, temp, and the shared package caches ("Shared package caches" below) — the machine cannot be damaged. Protected paths — the user's private directories (`~/Main` for this machine's owner; another user replaces that) and credential material — are unreachable, read and write. Everything else on the machine is readable, by design. Anything inside the repository may be destroyed or leaked.

This is a deny-list model: enumerate what is protected, allow the rest. An earlier version of this skill did the opposite — mask all of `$HOME`, then carve back in what work needs — and every new tool on the host broke it. Never reintroduce allow-list masking, `allowRead` carve-ins, or toolchain probing: the default sandbox is already read-open and write-closed (measured, below), so the only lists to maintain are the protected paths and the command denies.

What each agent enforces — measured on Linux against Claude Code 2.1.241, codex-cli 0.148.0, and pi-sandbox 0.6.5, not taken from docs:

| Agent | Writes outside the repo | Protected-path reads | Notes |
| --- | --- | --- | --- |
| Claude Code | blocked | blocked | Bash covered by `sandbox.filesystem.denyRead` (bwrap mask), native tools by `permissions.deny` |
| Pi | blocked | blocked | Shell and native tools both |
| Codex | blocked | **allowed** | No mode confines reads; by design, not a misconfiguration. **Interactive use only — never unattended loops** |

Three layers, strongest first: the OS sandbox (the boundary), command deny rules (policy on top), model instructions (not a security layer). Egress is open where the agent honours the setting. Tell the user the consequences plainly: open reads plus open egress mean a prompt injection in anything an agent reads can leak anything readable — other repos, dotfiles, shell history, transcripts. The credential denies and secret-file globs bound that damage; they are the main line now, not a second layer. Secrets on this machine are throwaway by policy (production secrets come from a secret manager, never the disk).

## Invariants

No problem you hit makes it valid to break one of these:

- Fail closed. Claude Code: `failIfUnavailable: true`, `allowUnsandboxedCommands: false`. Codex: an explicit `sandbox_mode`. Pi: hard denies, no ask-to-escape. A sandbox that cannot start must stop the agent, not wave it through.
- Never write config that only looks like a boundary. If the CLI accepts a key and then ignores it, leave the key out and say so in a comment. Trust what was measured, not what the docs promise.
- Cover the native file tools, not only Bash. Claude Code's `filesystem.denyRead` reaches the native Read tool only as a permission *prompt* (fails closed headless, but a prompt is not a deny) — the `permissions.deny` rules are the hard layer. Never generate the `sandbox` block without its `permissions` block.
- No agent may edit its own policy — or another agent's. Deny rules and read-only mounts close that path for Claude Code and Pi; for Codex, only the user's review does (cautions). Lasting rule for the user either way: review `git diff -- .claude/ .codex/ .pi/` before each session.
- Codex never runs unattended. It cannot hide the protected paths — `~/Main` is readable to it in every mode. Generate its config for interactive use if the project wants it, and say the limitation plainly every time.
- Never generate or recommend the bypass flags. `--dangerously-skip-permissions` auto-approves everything the deny rules do not name (including native-tool reads of `denyRead` paths, which are only a prompt away); `--dangerously-bypass-approvals-and-sandbox` turns the Codex sandbox off entirely.
- Print privileged commands (`bubblewrap`/`socat` installs, AppArmor changes) for the human to run, then verify them; never run them yourself. The Pi extensions are third-party code inside the trust boundary: pin their versions and point the user at their sources before they install.

## The conversation

Detect the OS and installed agent CLIs, inspect the repository's stack, then settle these with the user, recommending a default for each:

1. **Platform** — macOS needs nothing. Linux and WSL2 need `bubblewrap` and `socat`; print the install command. Ubuntu 24.04+ also needs the AppArmor bwrap fix (cautions), or no Claude Code Bash command runs at all. Windows outside WSL2: stop, and get the user into WSL2 first.
2. **Agents** — which of the three this project uses. Generate config only for those, and show the enforcement table before they choose — including that Codex is interactive-only here. Pi's sandbox is two extensions — core Pi has none, and project trust is not a sandbox: `pi-sandbox` is the OS boundary, `@gotgenes/pi-permission-system` the hard-deny policy layer. One pinned global install per machine serves every project — `pi install npm:pi-sandbox@<version>` and `pi install npm:@gotgenes/pi-permission-system@<version>`. Pin is the security control: an unpinned entry silently auto-upgrades, and upgrades have changed enforcement semantics before. Check `~/.pi/agent/settings.json` for unpinned entries and have the user pin them. This repo's [package.json](package.json) mirrors the pinned versions so Dependabot flags new releases; a release PR means review-and-re-verify, never auto-merge.
3. **Protected directories** — `~/Main` is the default on this machine; ask which other directories should be unreachable and add them to every agent's deny lists. Missing-path denies are tolerated (measured: the Claude Code sandbox starts fine with a `denyRead` entry that does not exist on disk), so the list is a stable superset — no trimming against the host, no re-run when tools are installed. Say what is *not* protected: every other repo, dotfiles, and agent transcripts are readable by design. Never deny the agents' own transcript directories (`~/.claude/projects` etc.) — Claude Code spills oversized tool output there and must read it back; transcripts protect nothing that open reads don't already expose.
4. **Command denies** — `sudo`, `su`, `doas`, `pkexec`, `ssh`, `scp`, `git push` are the default. Deploy tools (`terraform`, `kubectl`, `aws`, `gcloud`) get denies only when installed on the host — ask which.
5. **Container sockets** — when docker/podman are installed and the user is in the `docker` group, the socket is a decision, not a default: an agent that reaches it can `docker run -v /:/host` and get root on the host — a complete escape from every layer here. If the project's workflow runs on containers, present that trade-off and let the user choose. Allowed: drop the socket-path denies, set Pi's `allowAllUnixSockets: true`, and record the choice in a dated config comment. Denied: add `Bash(docker:*)`/`Bash(podman:*)` denies and keep the socket paths in Pi's `denyRead`.
6. **Unix sockets** — Claude Code and pi-sandbox block `socket(AF_UNIX)` through the same optional seccomp filter, and on Linux it is all-or-nothing: the per-path allowlists are macOS-only and silently ignored. Grep the sources *and tests* for `AF_UNIX`, `socketpair`, `sun_path`, or local-socket IPC — if the project creates any, its own checks will fail with `Operation not permitted` under the default. Present the choice and apply it to both agents at once: allow (`sandbox.network.allowAllUnixSockets: true` for Claude Code, `allowAllUnixSockets: true` for Pi) or keep blocked. Allowing does not open the container sockets from item 5.

If sandbox config already exists, this is an update: ask what the user wants changed and repair it, don't recreate it. Config generated by the old allow-list version of this skill (recognisable by `allowRead` carve-in lists and a `denyRead` of `~/` or `/home`) should be replaced with the current templates, keeping the project's own choices from items 3–6.

## Generate

### Write order

Your own agent's config takes effect the moment it lands: the running session re-initializes its sandbox, the policy directories become read-only, and the protected paths vanish. Do anything that needs them first — Pi schema verification, any `pi install` — then write the other agents' files, and your own agent's config **last**. If a lockout happens anyway: stage the remaining files in a directory at the repo root (the root stays writable) and hand the user one copy command for a separate terminal — never the `!` prefix, which runs inside the session's sandbox. Verification belongs to fresh sessions, after handover. A transient `apply-seccomp: unshare(CLONE_NEWUSER): Invalid argument` fails closed — retry once, and never diagnose host state from inside the sandbox.

### Templates

Fill the templates for the selected agents. The deny lists are the whole policy — nothing to probe on the read side. Adjust only: the protected directories from item 3, the command denies from item 4, the socket choices from items 5–6, the secret-glob root (`~/Code` on this machine) to wherever the user keeps repositories, and the cache carve-out paths ("Shared package caches" below).

| Agent       | Destination                                        | Template                                                                        |
| ----------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| Claude Code | `.claude/settings.json`                            | [claude-settings.json](assets/templates/claude-settings.json)                   |
| Codex       | `.codex/config.toml`, `.codex/rules/security.rules` | [codex-config.toml](assets/templates/codex-config.toml), [codex-security.rules](assets/templates/codex-security.rules) |
| Pi          | `.pi/sandbox.json`, `.pi/extensions/pi-permission-system/config.json` | [pi-sandbox.json](assets/templates/pi-sandbox.json), [pi-permission-system.json](assets/templates/pi-permission-system.json) |

### Shared package caches

Package managers must write their caches, and writes outside the repository are otherwise blocked — so the templates carve the machine-wide cache directories into the writable set (measured on 2.1.241: `filesystem.allowWrite` carve-outs work, writes persist to the real filesystem, and a nested `denyWrite` inside a carve-out wins). The dividing line is integrity verification, and it is a deliberate, accepted trade-off — say it in the handover:

- **Writable: verified caches.** npm's cacache, the pnpm store, uv, pip, cargo's registry (lockfile checksums), and the Go module cache (`go.sum`) all check content hashes at use, so a poisoned entry is caught or inert. Confirm pnpm's `verifyStoreIntegrity` has not been turned off. The residual risk — a cache poisoning that slips past verification and reaches the user's own shell in another project — is the one persistence channel this setup accepts, in exchange for repos needing no cache config at all.
- **Never writable: compiled-object caches.** ccache and Go's build cache feed unverified object code straight into future binaries — the templates deny them inside the carve-out (`~/.cache/ccache`, `~/.cache/go-build`), and Codex simply doesn't list them. A project that uses ccache points it into the repo instead: repo-local `CCACHE_DIR`, e.g. via a CMake preset `environment` block (build presets inherit the configure preset's environment).

While generating, confirm the carve-out paths match the host — `pnpm store path`, `npm config get cache`, `uv cache dir` — and add the stack's equivalents for managers not in the template. A mismatch fails closed: the install errors with `Read-only file system`, and the fix is adding the real path, never widening to `~/`.

### Claude Code cautions

Measured behaviour of `filesystem.denyRead` (2.1.241): a denied directory is masked with an empty tmpfs — its *contents* report `No such file or directory`, its *name* still shows in `ls ~` (it is a mount point), and a write into it "succeeds" into the tmpfs and evaporates. A denied *file* reports `Permission denied`. A native-tool Read of a denied path becomes a permission prompt — denied headless, but grantable interactively, which is why the `permissions.deny` twins stay.

- The `filesystem` block lives in `.claude/settings.json` so relative paths resolve against the project root — never move it to user-level settings. No `~/.*` dotfile globs anywhere in the config (measured on 2.1.238: they crash every Bash call at spawn; fail-closed). `denyRead` takes literal paths, not globs; secret-file globs belong in `permissions.deny` only.
- File denies must be spelled `Edit(path)` — Claude Code does not match `Write(path)` rules (Edit rules cover all file-editing tools). `Read(path)` rules match normally.
- The single `WebFetch(domain:*)` allow rule opens egress and does double duty: allow rules also pre-allow domains for the sandbox proxy, covering `curl` and `npm install`. It only applies after the workspace trust dialog — headless hosts need `hasTrustDialogAccepted: true` in `~/.claude.json`.
- Ubuntu 24.04+ AppArmor trap: every Bash command can fail with an apply-seccomp / nested-userns error. Check with `bwrap --dev-bind / / -- cat /proc/self/attr/current` (want `unconfined`). The fix, printed for the human: unload and disable the `bwrap-userns-restrict` profile, install a `flags=(unconfined)` AppArmor profile for `/usr/bin/bwrap` containing `userns,`, reload with `apparmor_parser -r`. Verify: `bwrap --unshare-all --dev-bind / / -- bwrap --unshare-user --dev-bind / / -- true` succeeds. Until fixed it fails closed — a blocked agent, not an exposed one.
- Self-policy, measured on 2.1.238: a live sandbox mounts the policy directories read-only to the shell. A session started before the config existed does not have that mount, so keep the `Edit(.claude/**)`/`Edit(.codex/**)`/`Edit(.pi/**)` denies — and re-check after upgrades.
- Deny beats allow with no way back: `Read(.env.*)` also hides a committed `.env.example` the project may tell agents to read. Where one exists, name the real variants (`.env.local`, ...) instead of the blanket glob. (Pi differs: there a later, more-specific allow wins.)
- Rc-file write denies must survive symlinks: `~/.zshrc → ~/dotfiles/zsh/.zshrc` makes the deny bypassable through its target. `ls -la` the rc files and deny the target directory (e.g. `Edit(~/dotfiles/**)`) when they are links.
- When the optional seccomp filter is installed, sandboxed shells cannot create `AF_UNIX` sockets — project code and tests die with `Operation not permitted` (measured on 2.1.241). `sandbox.network.allowAllUnixSockets: true` is the only Linux control; see conversation item 6.

### Codex cautions

- Codex confines writes and command execution, never reads — a probe under this config read a file from `$HOME`, and no mode changes it. `~/Main` is readable to Codex. Say it plainly, generate the config for interactive use only, and never include Codex in an unattended recipe.
- The beta permission-profile block that would confine reads passes `--strict-config` on 0.148.0 and is then ignored, so the template omits it. Re-check after each upgrade; adopt it if read confinement ships, and update the table above.
- Trust cuts both ways: project `.codex/` config loads only for a trusted project, yet trust alone turns the sandbox off. The template sets `sandbox_mode` explicitly, which overrides the trust default (verified). Check `~/.codex/config.toml` for a broad `trust_level = "trusted"` entry covering the user's home — under one, every repo without an explicit `sandbox_mode` has no sandbox at all. Tell the user to remove it.
- The rules DSL is command-prefix only — no path rules — and `workspace-write` leaves the whole repo writable, policy directories included. Under Codex, only the `git diff` review rule guards `.claude/`, `.codex/`, and `.pi/`.

### Pi cautions

- The templates' schemas belong to the extensions, not Pi — verify every key against the pinned versions (`npm pack` the tarballs, read the README and the shipped JSON schema) *before* your own agent's config lands. Two semantics to confirm for the pinned pi-sandbox: that `~` expands in the filesystem lists, and that `denyRead` beats the `allowRead: ["~/"]` that keeps home reads prompt-free — if deny does not take precedence, stop and say so rather than shipping an open boundary.
- Glob syntax, measured on pi-permission-system 26.3.1: `**` is not a token — it behaves as a plain `*`, which already crosses path separators. Write `*.env` (a leading `*` matches zero characters). Relative patterns also match in cwd-absolute form but not the reverse — pair `.pi/*` with a `*/.pi/*` twin. Ordering is last-match-wins: the `*.env.example` allow goes after the `*.env.*` deny. Validate the finished config against the package's shipped schema (`additionalProperties: false`).
- Project trust gates everything: pi-permission-system loads project config only for a project trusted in `~/.pi/agent/trust.json` — untrusted means the entire `.pi/` policy is silently skipped. Tell the user to accept the trust prompt on first run and confirm with `/sandbox`, watching for a `project_trust.skipped` warning.
- A global `~/.pi/agent/sandbox.json` merges its path and domain arrays with the project's — it can silently widen the policy. Check it before writing the project file.
- pi-sandbox refuses to initialize without ripgrep (`rg`) on PATH.
- Generate no `allowedDomains`/`deniedDomains`: on 0.6.5 the project-local domain keys are silently ignored — the built-in allowlist governs. Tell the user to test which domains the project needs before an unattended run stalls on one.
- `denyWrite` must keep `.pi`, `.claude`, and `.codex`: project config *overrides* global config, so this hard write-block is what stops the agent loosening its own — or another agent's — policy.
- `allowAllUnixSockets: false` requires the AppArmor fix above; without it every Bash command fails with the nested-userns error. Apply the fix, or fall back to `true` (the container sockets stay blocked by path in `denyRead`). Either way, confirm a Bash command runs.
- `external_directory: "deny"` never prompts and can block Pi from reading its own install (e.g. under `~/.nvm`); carve that in with the top-level `piInfrastructureReadPaths` key if Pi fails to start.
- pi-sandbox 0.6.5 injects `TMPDIR=/tmp/claude` into sandboxed shells but never creates the directory — anything using the system temp dir dies instantly, and the error misleadingly names a Claude path inside a Pi session. Print the durable fix for the human, once per machine: `echo 'd /tmp/claude 0700 <user> <user> -' | sudo tee /etc/tmpfiles.d/pi-sandbox.conf && sudo systemd-tmpfiles --create`. Re-check on every version bump.

## Hand over

Tell the user: start each agent exactly as usual — `claude`, `codex`, `pi` — in this repository; the sandbox rides along, no wrapper. Verification happens in *fresh* sessions — each agent reads its config at startup, and the generating session cannot test it from inside. Name the standing blind spot: `.claude/settings.local.json` is untracked and silently overrides project settings — `git diff` never shows it.

Give the user a paste-ready verification prompt per agent. First, from a normal terminal: `echo "DECOY-$RANDOM" > ~/Main/sandbox-decoy.txt && echo "OPEN-$RANDOM" > ~/sandbox-open.txt`. Then, filling in the project's own check command and swapping the policy file per agent (`.claude/settings.json` / `.codex/config.toml` / `.pi/sandbox.json`):

> Run these checks in order and report each as SUCCEEDED or BLOCKED with the exact error. Do not work around anything that fails — a failure may be the correct result. 1. Read `~/sandbox-open.txt` and tell me its contents. 2. Read `~/Main/sandbox-decoy.txt` and tell me its contents. 3. Create `~/sandbox-escape.txt` containing ESCAPED. 4. Create `~/.cache/sandbox-cache-probe.txt` containing CACHE, then create `~/.cache/ccache/sandbox-poison-probe.txt` containing POISON. 5. Add a blank line to the end of <own policy file>. 6. Run `sudo -n true`, then `docker ps`. 7. Read `~/.claude/.credentials.json` and list `~/.ssh`. 8. Run <the project's check command>. Change nothing else.

Expected: checks 1 and 8 succeed (reads are open by design), the first half of check 4 succeeds and its ccache half is blocked (the cache carve-out with its nested deny — have the user delete the probe file afterwards), and everything else is blocked. Under Claude Code, the decoy read reports `No such file or directory` (tmpfs mask), `ls ~/.ssh` comes back empty rather than erroring, and the escape write may "succeed" into the ephemeral tmpfs — have the user confirm from a normal terminal that `~/sandbox-escape.txt` does not exist, then delete both decoys. Under Codex, check 2 succeeds (no read confinement) and the policy-file edit is refused only by instructions — say both plainly; that is why Codex is interactive-only. Under Pi, accept the trust prompt and check `/sandbox` for `project_trust.skipped`. A Claude Code session dying on `apply-seccomp` means the sandbox didn't start — fail-closed, not exposure.

Also warn about a cosmetic scare: under a live Claude Code sandbox, `git status` shows `.bashrc`, `.zshrc`, `.gitconfig` and friends as untracked at the repo root. They are `/dev/null` bind mounts the sandbox creates to neutralise code-executing config — namespace-only, char devices, not on disk; a normal terminal shows nothing. Don't gitignore them.

Sandboxed Bash runs without prompts (Claude Code: `autoAllowBashIfSandboxed`; Codex: `approval_policy = "never"`), so sessions are already near-autonomous. For unattended runs give the exact commands — `claude -p --permission-mode acceptEdits` and `pi -p --approve`, **never `codex exec`** (no read confinement) — and repeat that the bypass flags undo this setup. The lasting rules: commit and push before unattended runs (the repository is the blast radius, `.git` included, and agents cannot push — the remote is the backup); no secrets on this machine the user cannot lose; the developer pushes from their own shell after review; review `git diff -- .claude/ .codex/ .pi/` before each session; a repository without this config has no protection — run the skill there first. Point at the levers outside the machine: spend caps in the provider consoles, scoped tokens (a `gh` token can delete repositories), dev-only secret-manager configs.

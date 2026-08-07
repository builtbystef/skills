---
name: set-up-sandbox
description: Sets a project up with a disposable container sandbox for a coding agent. In the sandbox, the agent can write anything and run anything, with full network access. The host filesystem stays out of reach. Produces a committed start script. The developer runs the script to enter the sandbox and start their agent.
disable-model-invocation: true
---

# Set Up Sandbox

Give the current repository a disposable container sandbox for coding agents. This session runs **on the host**, and it is the last step without a sandbox. Afterward, the developer runs `sandbox/start.sh`, gets a shell at `/workspace`, and starts the agent with permission prompts off. This is safe, because the blast radius is the repository.

The security model. Each step preserves it:

> Anything inside the repository may be destroyed or leaked. Everything outside the repository must be inaccessible.

The network is open — there is no egress control. For this reason, tell the user plainly: secrets that they cannot afford to leak do not belong in the repository.

## Invariants

A problem that you find never makes it valid to break one of these:

- Never use `--privileged`. Always use `--cap-drop=all` and `--security-opt=no-new-privileges`.
- Never mount `/`, `$HOME`, `~/.ssh`, `~/.aws`, `~/.gnupg`, or a host folder with agent configuration.
- Never expose a container-control socket (`podman.sock`, `docker.sock`). Such a socket is host root with another name.
- The only host mount is the repository, read-write at `/workspace`. Agent state lives in a named volume.
- Print privileged installations (the runtime, WSL2) for the human to run. Then verify them. Never run them yourself.

## The conversation

Detect the OS and the installed runtimes. Inspect the repository for its stack. Then settle three items with the user, in conversation. Give a recommendation for each item:

1. **Platform** — Windows outside WSL2: stop, and get the user into WSL2 first.
2. **Runtime** — rootless Podman, or Docker. Recommend rootless Podman when neither is settled. Make sure that the runtime operates before you continue (`podman info --format '{{.Host.Security.Rootless}}'` → `true`; for Docker, a hello-world run). The image runs as the non-root user `agent` (uid 1000) — agent CLIs refuse their full-permission flags under root. For this reason `{{user-flag}}` must keep the workspace ownership correct: rootless Podman gets `--userns=keep-id:uid=1000,gid=1000` (this maps the host user onto `agent`); rootful Docker gets `--user "$(id -u):$(id -g)"`.
3. **Image contents** — propose the stack toolchain, from what the repository shows. Ask which agent CLIs to include (Claude Code: `npm install -g @anthropic-ai/claude-code`; Codex: `npm install -g @openai/codex`; another CLI: the install command from the user, exactly as given). Use the base `ubuntu:24.04`, unless something indicates a different base.

If `sandbox/` exists, this is an update. Ask what the user wants changed. Repair the existing setup. Do not recreate it.

## Generate, build, smoke test

Fill [assets/templates/Containerfile](assets/templates/Containerfile) and [assets/templates/start.sh](assets/templates/start.sh) (executable). Commit both to `sandbox/`. Build `sandbox-<repo-name>`. Do not weaken the template's security flags. The resource limits are the user's to adjust. The script mounts exactly two items: the repository at `/workspace`, and a named volume at the container home. The developer logs the agent in one time, inside. The credential persists in the volume, and it never touches the host. The script itself runs on the host, and a sandboxed agent can edit it. That is the one intended hole. The header and the handover both give the answer: review `git diff -- sandbox/` before each start.

Then prove that the sandbox holds. Run each check through `./sandbox/start.sh bash -c '<check>'`:

1. Exactly two mounts (`inspect` a container that runs).
2. `/workspace` is writable. Host paths are invisible.
3. The network is up: `curl -sI https://example.com`. If DNS fails, but a raw IP operates, that is the rootless-network quirk on hosts with systemd-resolved. Add `--dns 1.1.1.1` (or the host's real upstream) to the script, and test again.
4. Each installed agent CLI answers `--version`.
5. Non-root: `id -u` inside is `1000`, not `0`. Root in the container makes agent CLIs refuse their full-permission flags, and that defeats the purpose of the sandbox.
6. Ownership round-trip: run `touch /workspace/.sandbox-check` inside. Confirm on the host that the user owns the file. Then delete the file. Wrong ownership means that `{{user-flag}}` is wrong for this runtime.

A failed check is a finding. Repair, and test again. All checks must be green before the handover.

## Hand over

Tell the user: `./sandbox/start.sh` → a shell at `/workspace`. The user starts the agent — full-permission mode is the point. Give the exact command for each CLI that they had included (Claude Code: `claude --dangerously-skip-permissions`; Codex: `codex --dangerously-bypass-approvals-and-sandbox`; another CLI: its equivalent). Never put an agent start into `start.sh`. The shell is the handover point. The developer selects the agent. Log the agent in one time, inside; the login persists. **Push from the host** — host keys never enter the sandbox. The two lasting rules: no secrets in the repository that the user cannot lose, and review `git diff -- sandbox/` before each start.

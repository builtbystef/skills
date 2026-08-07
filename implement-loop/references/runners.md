# Runner recipes — LOOP_AGENT_CMD

`LOOP_AGENT_CMD` is a shell command that the loop script runs one time for each iteration. The contract:

- The command runs **one full non-interactive agent session** in the current folder, and it exits when the session ends.
- The command receives the iteration prompt **on stdin**. Exception: if the command contains the placeholder `{PROMPT_FILE}`, the script substitutes the path of the prompt file, and it does not pipe.
- The command must never prompt a human. Anything interactive stalls until `LOOP_TIMEOUT` (default 3600 s) kills it, and the iteration counts as failed.

An unattended session must have the power to act without questions. Anything that prompts a human stalls until the timeout kills it. For this reason, the recipes below skip permissions fully. For the same reason, the loop belongs inside the project's container sandbox (`/set-up-sandbox`, then a session inside `./sandbox/start.sh`): contained, full autonomy costs only the repository. Without a sandbox, the same recipes give each iteration unconfined shell access to the machine and its credentials. That is the user's decision to make, with the risk stated plainly.

## Claude Code

```sh
LOOP_AGENT_CMD='claude -p --dangerously-skip-permissions --model <model>'
```

Pin the model explicitly. The CLI's default can change between runs, and run-to-run consistency is part of what makes an unattended loop debuggable.

Inside the sandbox, this is the full story: full autonomy, with the blast radius limited to the repository (this is why no secret that the user cannot lose belongs in it). Without a sandbox, remember what the flag's name says: any shell command, any file, no confirmation, on the host.

## OpenAI Codex

```sh
LOOP_AGENT_CMD='codex exec --full-auto'
```

`codex exec` is the non-interactive mode, and it reads the prompt from stdin when there is no prompt argument. `--full-auto` permits edits and command execution inside Codex's own sandbox. When the loop already runs inside the project's container sandbox, `codex exec --dangerously-bypass-approvals-and-sandbox` is the equivalent of the Claude recipe, with the same containment logic. Pin the model here too (`--model`). Flags move between releases. Check `codex exec --help` if a run dies immediately.

## Any other agent

Any CLI that can run one non-interactive session operates here. If it takes a prompt file, and not stdin, use the placeholder:

```sh
LOOP_AGENT_CMD='someagent run --auto --prompt-file {PROMPT_FILE}'
```

## Script flavors

The loop script comes in two flavors with identical behavior: the same usage, knobs, report protocol, status values, and exit codes. Select by what is installed, and by what the user prefers to read:

| Script | Start | Needs |
| --- | --- | --- |
| `loop.sh` | `bash loop.sh <run-dir>` | Bash + GNU `timeout` (macOS: `brew install coreutils`) |
| `loop.py` | `python3 loop.py <run-dir>` | Python 3.8+, stdlib only |

The Python flavor controls timeouts natively. It does not need GNU `timeout`.

## Knobs

| Env | Default | Meaning |
| --- | --- | --- |
| `LOOP_VERIFY_CMD` | off | An independent check suite that runs after each `closed`. A failure reclassifies the iteration as failed. Set it to the project's test or lint command, whenever one exists |
| `LOOP_TIMEOUT` | `3600` | Seconds for each iteration (and for each verify run). An overrun kills the session, and the iteration counts as failed |
| `LOOP_MAX_RUNTIME` | off | A wall-clock limit for the full run, in seconds — the limit for overnight runs |
| `LOOP_SPLICE_CAP` | `5` | The maximum number of discovered blockers added to the queue in one run |
| `LOOP_STALL_LIMIT` | `3` | The number of iterations in a row without a closure, before the run stops |

## Cost ceiling

A run has an iteration limit by construction: each queued issue runs at most two times (one retry), and at most `LOOP_SPLICE_CAP` blockers can join the queue. For this reason, the worst case is `2 × (queue length + LOOP_SPLICE_CAP)` agent sessions. Price a run against that number before the start. Set `LOOP_MAX_RUNTIME` as the blunt backstop for overnight runs.

Whichever flavor runs, start it from inside the project's git repository, with a clean working tree.

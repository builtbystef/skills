# Runner recipes — LOOP_AGENT_CMD

`LOOP_AGENT_CMD` is a shell command that the loop script runs one time for each iteration. The contract:

- The command runs **one full non-interactive agent session** in the current folder, and it exits when the session ends.
- The command receives the iteration prompt **on stdin**. Exception: if the command contains the placeholder `{PROMPT_FILE}`, the script substitutes the path of the prompt file, and it does not pipe.
- The command must never prompt a human. Anything interactive stalls until `LOOP_TIMEOUT` (default 3600 s) kills it, and the iteration counts as failed.

Run these recipes inside the project's container sandbox (`./sandbox/start.sh`). They skip permission prompts; outside that sandbox, they give each iteration unconfined access to the machine and its credentials.

## Claude Code

```sh
LOOP_AGENT_CMD='claude -p --dangerously-skip-permissions --model <model> --effort <effort>'
```

Pin the model and effort. Claude Code supports `low`, `medium`, `high`, `xhigh`, and `max`, depending on the model.

## OpenAI Codex

```sh
LOOP_AGENT_CMD='codex exec --dangerously-bypass-approvals-and-sandbox --model <model> --config model_reasoning_effort=<effort>'
```

Pin the model and `model_reasoning_effort`; supported effort levels depend on the model.

## Any other agent

Any non-interactive agent CLI works. For a prompt file, use:

```sh
LOOP_AGENT_CMD='someagent run --auto --prompt-file {PROMPT_FILE}'
```

## Script flavors

The two flavors behave identically:

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

A queued issue runs at most twice, and up to `LOOP_SPLICE_CAP` blockers may join. Worst case: `2 × (queue length + LOOP_SPLICE_CAP)` sessions. Set `LOOP_MAX_RUNTIME` for overnight runs.

Whichever flavor runs, start it from inside the project's git repository, with a clean working tree.

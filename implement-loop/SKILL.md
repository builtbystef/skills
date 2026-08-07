---
name: implement-loop
description: Drives a set of tracker issues to done through a loop. Each issue gets one fresh agent session. The tracker and git are the only memory between iterations. Use to implement explicit issue refs or a spec issue's sub-issues unattended, or to triage ready work into an ordered run first.
argument-hint: "issue refs, or a spec issue ref; no argument starts triage"
disable-model-invocation: true
---

# Implement Loop

One run, many issues. A fresh session completes each issue. This session is the **operator**: it assembles the queue, starts the loop script ([scripts/loop.sh](scripts/loop.sh) or [scripts/loop.py](scripts/loop.py) — identical behavior, selected in preflight), watches the run, and reports. Each iteration is a disposable session that follows the project's `implement` skill on exactly one issue. The loop stays thin, because `implement` already carries the discipline: claim, build with tests first, escalate on decisions, close or release. The tracker and the git history are the only memory between iterations. The run folder is operator state, not a record.

If the `docs/` folder or `docs/TRACKER.md` is missing, stop. Ask the user to run `/set-up-for-agents`. The `implement` skill must also be installed in this project. If it is not, stop and say so.

The recommended place for a loop is inside the project's container sandbox. The iterations run with permission prompts off, and the sandbox limits their blast radius to the repository. If the session is not in a sandbox, and the repository has no `sandbox/`, suggest this sequence: run `/set-up-sandbox` first, then start a session inside `./sandbox/start.sh`, and invoke this skill again there. A run without a sandbox is the user's decision. Do not block on it. But say plainly that each iteration then has full, unconfined shell access to the machine.

While the loop runs, the loop owns the working tree. Do not edit files. Do not claim issues. Do not commit. A dirty tree leaks into the next iteration's commit.

## Steps

1. **Assemble the queue.** Three intake forms:
   - **Issue refs** — fetch each one. Drop the closed issues. Flag the issues that are claimed or that have the label `needs-review`, and ask whether to include them.
   - **A spec issue** (label `spec`) — its open sub-issues are the queue. The spec itself never enters the queue.
   - **Nothing** — triage: list the ready work; show it numbered, with priority and blocking edges; recommend the issues for the run, and their order; iterate with the user. Gaps in the backlog are not yours to fill here. Point to `/create-issues` or `/maintain-codebase` instead.

   Order the queue blockers first, then by priority. An issue must come after everything that blocks it. Show the final ordered queue in one list. This step is complete when the user approves the queue.

2. **Preflight.** In this order:
   - The working tree must be clean. A dirty tree means stop. The commit or the stash is the user's move. The branch also: the run puts commits on the current branch, so suggest a branch or a worktree now, if the user wants isolation.
   - Find the project's `implement` skill file (for example `.claude/skills/implement/SKILL.md` or `.agents/skills/implement/SKILL.md`). Iterations read it by path.
   - Settle the script flavor. The loop exists as `loop.sh` and `loop.py`, with identical behavior. Select by what the user has installed and prefers to read. `loop.sh` needs Bash plus GNU `timeout`. `loop.py` needs Python 3.8+, and it controls timeouts natively, without GNU `timeout`. Ask which one the user prefers. Bash is the safe default when the user has no preference.
   - Settle the runner command with the user. Read [references/runners.md](references/runners.md), and propose the default unattended recipe. The cost, and (without a sandbox) the permission posture, are the user's to accept. For this reason, say plainly what the recipe lets sessions do.
   - Settle the verify command. Propose the project's check suite (the entry file's Checks section usually has it) as `LOOP_VERIFY_CMD`. It runs again after each `closed` outcome, outside the worker session. It is the run's only backpressure that the worker cannot game. Recommend it whenever the project has checks. Without it, you trust each session's self-report.
   - Create the run folder `.implement-loop/{{UTC-timestamp}}/`. Make sure that `.implement-loop/` is in `.gitignore` (append it if it is missing — that one edit is permitted before the start).
   - Write `queue.txt` — one ref for each line, in the approved order.
   - Copy [assets/templates/iteration-prompt.md](assets/templates/iteration-prompt.md) into the run folder as `prompt-template.md`. Fill `{{REPORT_FILE}}` (the absolute path of the run's `report.log`) and `{{IMPLEMENT_SKILL_PATH}}` (the absolute path found above). Do not touch `{{REF}}`. The script fills it for each iteration.

   This step is complete when the run folder holds `queue.txt` and `prompt-template.md`.

3. **Start.** Start the selected script detached, so that the run survives this session:

   ```sh
   LOOP_AGENT_CMD='<runner command>' nohup <launcher> <run-dir> >> <run-dir>/nohup.out 2>&1 &
   ```

   Here `<launcher>` is `bash <skill-dir>/scripts/loop.sh` or `python3 <skill-dir>/scripts/loop.py`.

   The knobs, all optional: `LOOP_VERIFY_CMD` (an independent check suite after each closure), `LOOP_TIMEOUT` (seconds for each iteration and each verify run, default 3600 — a stuck session counts as failed), `LOOP_MAX_RUNTIME` (a wall-clock limit for the full run, default off), `LOOP_SPLICE_CAP` (default 5), `LOOP_STALL_LIMIT` (default 3). This step is complete when the script runs, and `run.log` shows the first iteration.

4. **Operate.** Watch `run.log` and `report.log`. Tell the user what completes, when it completes. The protocol that the script runs: one session for each ref. Each session ends with one outcome line in `report.log` — `closed`, `needs-review`, `blocked-by <ref>`, or `failed`, with a reason. A `closed` counts only after `LOOP_VERIFY_CMD` passes (when set) — a failed verify run reclassifies the iteration as failed. A `failed` outcome (or silence, or a timeout) gets one retry, then a skip. A `blocked-by` outcome adds the blocker to the queue, before its dependent. `LOOP_SPLICE_CAP` limits this, so that a run can grow a little, but it cannot wander. After `LOOP_STALL_LIMIT` iterations in a row without a closure, the full run stops — at that point something systemic is wrong, and more iterations burn money. The script also enforces two invariants between iterations, and it stops on both: the working tree must come back clean, and HEAD must stay on the start branch. Work past a violation is how entropy compounds. If the user leaves during the run, the run continues. A later session finds everything in the newest `.implement-loop/` folder. This step is complete when the script has exited — `status` in the run folder reads `done`, `halted-stall`, `halted-runtime`, `halted-dirty`, or `halted-branch`.

5. **Report.** Trust, then verify. Before you compose the report, compare the report lines with the tracker: each `closed` issue is closed, and each `needs-review` issue has the label. A mismatch is a finding to show, not a line to repeat. Then compose the end-of-run report from `report.log`, `outcomes.txt`, and the remainder of `queue.txt`: the closed issues; the issues that wait for the user (`needs-review` — say what each one needs; the note on the issue has it); the issues blocked, skipped, or never run; the blockers that the run discovered and added. `run.log` records HEAD before each iteration. For this reason, one iteration's exact diff is `head(N)..head(N+1)`. Use it when the user wants to inspect or reverse one issue's work. Then the next moves:
   - Suggest `/review-code` over the run's full diff.
   - The queue came from a spec issue, and each sub-issue closed → write the run's outcome in a note on the spec issue. Tell the user that the spec is ready for review and closure. The loop never closes the spec itself.
   - Some issues stay open → to continue, run `/implement-loop` again, with the remaining refs. The tracker's claims and notes make re-entry safe.

   This step is complete when the user knows the state of each queued issue, and the next move.

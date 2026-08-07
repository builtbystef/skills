#!/usr/bin/env python3
"""Runner for the implement-loop skill: one fresh agent session per
queued issue, sequentially. The tracker and git are the durable memory
between iterations; this directory holds operator state only.

Behavior-identical to loop.sh — same usage, env knobs, report protocol,
status values, and exit codes. Needs only Python 3.8+ stdlib (timeouts are
handled natively; GNU `timeout` is not required).

Usage:  python3 loop.py <run-dir>
  <run-dir> must contain:
    queue.txt           one issue ref per line, blockers-first order
    prompt-template.md  iteration prompt with {{REF}} left unfilled

Env:
  LOOP_AGENT_CMD     required. Shell command that runs ONE non-interactive
                     agent session in the current directory and exits when
                     the session ends. Receives the prompt on stdin, or via
                     a {PROMPT_FILE} placeholder substituted with the
                     prompt's path. Recipes: references/runners.md.
  LOOP_VERIFY_CMD    optional. Independent check suite (tests/lint) run
                     after every 'closed' report; failure reclassifies the
                     iteration as failed. Backpressure outside the worker.
  LOOP_TIMEOUT       seconds per iteration and per verify (default 3600);
                     overrun = failed
  LOOP_MAX_RUNTIME   whole-run wall-clock cap in seconds (default 0 = off)
  LOOP_SPLICE_CAP    max discovered blockers spliced into the queue (default 5)
  LOOP_STALL_LIMIT   consecutive iterations without a close before the run
                     halts (default 3)

Protocol: each session must append one line to report.log —
  <ref> closed|needs-review|blocked|failed -- <reason>
  <ref> blocked-by <blocker-ref> -- <reason>
No line within the timeout counts as failed. failed earns one retry, then a
skip. blocked-by splices the blocker in ahead of its dependent, capped so a
run can grow a little but never wander.

Invariants enforced between iterations: the working tree must be clean and
HEAD must stay on the launch branch — a violation halts the run rather than
letting entropy compound. HEAD is logged before every iteration, so
iteration N's diff is exactly head(N)..head(N+1).

Exit / status: 0 done · 2 halted-stall · 3 halted-runtime ·
               4 halted-dirty / halted-branch
"""

import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn


def die(msg: str) -> NoReturn:
    print(msg, file=sys.stderr)
    sys.exit(1)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def run_with_timeout(
    cmd: str, timeout: int, stdin_path: Path | None, out_path: Path
) -> int:
    """Run cmd via bash -c in its own process group; kill the group on
    timeout (SIGTERM, then SIGKILL after a 30s grace). Returns 124 on
    timeout, mirroring GNU timeout."""
    stdin_file = open(stdin_path, "rb") if stdin_path else None
    try:
        with open(out_path, "wb") as out:
            proc = subprocess.Popen(
                ["bash", "-c", cmd],
                stdin=stdin_file if stdin_file else subprocess.DEVNULL,
                stdout=out,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                return proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
                return 124
    finally:
        if stdin_file:
            stdin_file.close()


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: loop.py <run-dir>")
    run_dir = Path(sys.argv[1]).resolve()
    queue = run_dir / "queue.txt"
    template = run_dir / "prompt-template.md"
    report = run_dir / "report.log"
    log_file = run_dir / "run.log"
    outcomes_file = run_dir / "outcomes.txt"

    agent_cmd = os.environ.get("LOOP_AGENT_CMD") or die(
        "set LOOP_AGENT_CMD (see references/runners.md)"
    )
    verify_cmd = os.environ.get("LOOP_VERIFY_CMD", "")
    timeout = int(os.environ.get("LOOP_TIMEOUT", "3600"))
    max_runtime = int(os.environ.get("LOOP_MAX_RUNTIME", "0"))
    splice_cap = int(os.environ.get("LOOP_SPLICE_CAP", "5"))
    stall_limit = int(os.environ.get("LOOP_STALL_LIMIT", "3"))

    if not queue.is_file() or not queue.stat().st_size:
        die(f"queue.txt missing or empty in {run_dir}")
    if not template.is_file():
        die(f"prompt-template.md missing in {run_dir}")
    if "{{REF}}" not in template.read_text():
        die("prompt-template.md has no {{REF}} placeholder")
    try:
        git("rev-parse", "--show-toplevel")
    except subprocess.CalledProcessError:
        die("current directory is not a git repository")
    if git("status", "--porcelain"):
        die("working tree not clean — commit or stash before launching")

    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    start_epoch = time.time()

    report.touch()
    outcomes_file.touch()

    def log(msg: str) -> None:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(log_file, "a") as f:
            f.write(f"{stamp} {msg}\n")

    def outcome(ref: str, what: str) -> None:
        with open(outcomes_file, "a") as f:
            f.write(f"{ref} {what}\n")

    def halt(status: str, why: str, code: int) -> None:
        log(f"halting: {why}")
        (run_dir / "status").write_text(status + "\n")
        sys.exit(code)

    def read_queue() -> list:
        return [l for l in queue.read_text().splitlines()]

    def write_queue(lines: list) -> None:
        queue.write_text("".join(l + "\n" for l in lines))

    (run_dir / "status").write_text("running\n")
    n_queued = len([l for l in read_queue() if l])
    log(
        f"run start: {n_queued} queued on branch {branch}, timeout={timeout}s "
        f"max_runtime={max_runtime}s splice_cap={splice_cap} "
        f"stall_limit={stall_limit} verify={verify_cmd or '<none>'}"
    )

    it = 0
    stall = 0
    splices = 0
    attempted: set = set()
    retried: set = set()

    while True:
        q = read_queue()
        if not any(q):
            break
        if max_runtime > 0 and time.time() - start_epoch >= max_runtime:
            halt(
                "halted-runtime",
                f"wall-clock cap of {max_runtime}s reached with queue remaining",
                3,
            )

        ref, q = q[0], q[1:]
        write_queue(q)
        if not ref:
            continue

        it += 1
        attempted.add(ref)
        log(
            f"iteration {it}: {ref} (HEAD {git('rev-parse', '--short', 'HEAD')} on {branch})"
        )

        marker = len(report.read_text().splitlines())
        prompt = run_dir / f"iteration-{it}-prompt.md"
        prompt.write_text(template.read_text().replace("{{REF}}", ref))

        out_path = run_dir / f"iteration-{it}.out"
        if "{PROMPT_FILE}" in agent_cmd:
            rc = run_with_timeout(
                agent_cmd.replace("{PROMPT_FILE}", str(prompt)), timeout, None, out_path
            )
        else:
            rc = run_with_timeout(agent_cmd, timeout, prompt, out_path)
        if rc == 124:
            log(f"iteration {it}: timed out after {timeout}s")

        # Invariants before anything else — a violation is systemic, not issue-specific.
        now_branch = git("rev-parse", "--abbrev-ref", "HEAD")
        if now_branch != branch:
            halt(
                "halted-branch",
                f"branch drifted {branch} -> {now_branch} during iteration {it} ({ref})",
                4,
            )
        if git("status", "--porcelain"):
            halt(
                "halted-dirty",
                f"dirty working tree after iteration {it} ({ref}) — see git status",
                4,
            )

        line = ""
        for candidate in report.read_text().splitlines()[marker:]:
            fields = candidate.split()
            if fields and fields[0] == ref:
                line = candidate
        fields = line.split()
        status = fields[1] if len(fields) > 1 else ""
        log(f"iteration {it}: reported '{line or '<no report line>'}' (exit {rc})")

        if status == "closed" and verify_cmd:
            vrc = run_with_timeout(
                verify_cmd, timeout, None, run_dir / f"iteration-{it}-verify.out"
            )
            if vrc == 0:
                log(f"iteration {it}: verify passed")
            else:
                log(
                    f"iteration {it}: reported closed but verify failed — reclassified as failed"
                )
                status = "failed-verify"

        if status == "closed":
            stall = 0
            outcome(ref, "closed")
            continue
        elif status == "needs-review":
            outcome(ref, "needs-review")
        elif status == "blocked-by":
            blocker = fields[2] if len(fields) > 2 else ""
            if (
                blocker
                and blocker != ref
                and splices < splice_cap
                and blocker not in attempted
                and blocker not in read_queue()
            ):
                splices += 1
                write_queue([blocker, ref] + read_queue())
                log(f"spliced {blocker} ahead of {ref} ({splices}/{splice_cap})")
                outcome(ref, f"requeued-after {blocker}")
            else:
                log(
                    f"not splicing '{blocker}' for {ref} (cap reached, already seen, or malformed)"
                )
                outcome(ref, f"blocked-by {blocker or 'unknown'}")
        elif status == "blocked":
            outcome(ref, "blocked")
        else:  # failed, failed-verify, malformed, silence, or timeout
            if ref in retried:
                log(f"{ref} failed twice — skipping")
                outcome(ref, status or "failed")
            else:
                retried.add(ref)
                write_queue([ref] + read_queue())
                log(f"{ref} failed — retrying once")
                outcome(ref, "retrying")

        stall += 1
        if stall >= stall_limit:
            halt("halted-stall", f"{stall} consecutive iterations without a close", 2)

    log(
        f"run done: queue drained after {it} iterations, HEAD {git('rev-parse', '--short', 'HEAD')}"
    )
    (run_dir / "status").write_text("done\n")


if __name__ == "__main__":
    main()

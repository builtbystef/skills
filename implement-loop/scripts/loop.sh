#!/usr/bin/env bash
# Runner for the implement-loop skill: one fresh agent session per
# queued issue, sequentially. The tracker and git are the durable memory
# between iterations; this directory holds operator state only.
#
# Usage:  loop.sh <run-dir>
#   <run-dir> must contain:
#     queue.txt           one issue ref per line, blockers-first order
#     prompt-template.md  iteration prompt with {{REF}} left unfilled
#
# Env:
#   LOOP_AGENT_CMD     required. Shell command that runs ONE non-interactive
#                      agent session in the current directory and exits when
#                      the session ends. Receives the prompt on stdin, or via
#                      a {PROMPT_FILE} placeholder substituted with the
#                      prompt's path. Recipes: references/runners.md.
#   LOOP_VERIFY_CMD    optional. Independent check suite (tests/lint) run
#                      after every 'closed' report; failure reclassifies the
#                      iteration as failed. Backpressure outside the worker.
#   LOOP_TIMEOUT       seconds per iteration and per verify (default 3600);
#                      overrun = failed
#   LOOP_MAX_RUNTIME   whole-run wall-clock cap in seconds (default 0 = off)
#   LOOP_SPLICE_CAP    max discovered blockers spliced into the queue (default 5)
#   LOOP_STALL_LIMIT   consecutive iterations without a close before the run
#                      halts (default 3)
#
# Protocol: each session must append one line to report.log —
#   <ref> closed|needs-review|blocked|failed -- <reason>
#   <ref> blocked-by <blocker-ref> -- <reason>
# No line within the timeout counts as failed. failed earns one retry, then a
# skip. blocked-by splices the blocker in ahead of its dependent, capped so a
# run can grow a little but never wander.
#
# Invariants enforced between iterations: the working tree must be clean and
# HEAD must stay on the launch branch — a violation halts the run rather than
# letting entropy compound. HEAD is logged before every iteration, so
# iteration N's diff is exactly head(N)..head(N+1).
#
# Exit / status: 0 done · 2 halted-stall · 3 halted-runtime ·
#                4 halted-dirty / halted-branch

set -u

RUN_DIR=${1:?usage: loop.sh <run-dir>}
RUN_DIR=$(cd "$RUN_DIR" && pwd)
QUEUE="$RUN_DIR/queue.txt"
TEMPLATE="$RUN_DIR/prompt-template.md"
REPORT="$RUN_DIR/report.log"
LOG="$RUN_DIR/run.log"
OUTCOMES="$RUN_DIR/outcomes.txt"

AGENT_CMD=${LOOP_AGENT_CMD:?set LOOP_AGENT_CMD (see references/runners.md)}
VERIFY_CMD=${LOOP_VERIFY_CMD:-}
TIMEOUT=${LOOP_TIMEOUT:-3600}
MAX_RUNTIME=${LOOP_MAX_RUNTIME:-0}
SPLICE_CAP=${LOOP_SPLICE_CAP:-5}
STALL_LIMIT=${LOOP_STALL_LIMIT:-3}

[ -s "$QUEUE" ] || { echo "queue.txt missing or empty in $RUN_DIR" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "prompt-template.md missing in $RUN_DIR" >&2; exit 1; }
grep -q '{{REF}}' "$TEMPLATE" || { echo "prompt-template.md has no {{REF}} placeholder" >&2; exit 1; }
command -v timeout >/dev/null || { echo "GNU 'timeout' not found (macOS: brew install coreutils)" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "current directory is not a git repository" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean — commit or stash before launching" >&2; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
START_EPOCH=$(date +%s)

touch "$REPORT" "$OUTCOMES"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }
outcome() { printf '%s %s\n' "$1" "$2" >>"$OUTCOMES"; }
halt() { log "halting: $2"; echo "$1" >"$RUN_DIR/status"; exit "$3"; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
in_queue() { grep -qxF "$1" "$QUEUE"; }
push_front() { # push_front <line>...  (first argument ends up first in queue)
  local tmp="$QUEUE.tmp"
  printf '%s\n' "$@" >"$tmp"
  cat "$QUEUE" >>"$tmp"
  mv "$tmp" "$QUEUE"
}

echo running >"$RUN_DIR/status"
log "run start: $(wc -l <"$QUEUE" | tr -d ' ') queued on branch $BRANCH, timeout=${TIMEOUT}s max_runtime=${MAX_RUNTIME}s splice_cap=$SPLICE_CAP stall_limit=$STALL_LIMIT verify=${VERIFY_CMD:-<none>}"

it=0 stall=0 splices=0 attempted="" retried=""

while [ -s "$QUEUE" ]; do
  if [ "$MAX_RUNTIME" -gt 0 ] && [ $(($(date +%s) - START_EPOCH)) -ge "$MAX_RUNTIME" ]; then
    halt halted-runtime "wall-clock cap of ${MAX_RUNTIME}s reached with queue remaining" 3
  fi

  ref=$(head -n1 "$QUEUE")
  tail -n +2 "$QUEUE" >"$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  [ -n "$ref" ] || continue

  it=$((it + 1))
  in_list "$ref" "$attempted" || attempted="$attempted $ref"
  log "iteration $it: $ref (HEAD $(git rev-parse --short HEAD) on $BRANCH)"

  marker=$(wc -l <"$REPORT")
  prompt="$RUN_DIR/iteration-$it-prompt.md"
  template_body=$(cat "$TEMPLATE")
  printf '%s\n' "${template_body//'{{REF}}'/$ref}" >"$prompt"

  if [[ "$AGENT_CMD" == *'{PROMPT_FILE}'* ]]; then
    timeout -k 30 "$TIMEOUT" bash -c "${AGENT_CMD//'{PROMPT_FILE}'/$prompt}" \
      >"$RUN_DIR/iteration-$it.out" 2>&1
  else
    timeout -k 30 "$TIMEOUT" bash -c "$AGENT_CMD" <"$prompt" \
      >"$RUN_DIR/iteration-$it.out" 2>&1
  fi
  rc=$?
  [ "$rc" -eq 124 ] && log "iteration $it: timed out after ${TIMEOUT}s"

  # Invariants before anything else — a violation is systemic, not issue-specific.
  now_branch=$(git rev-parse --abbrev-ref HEAD)
  [ "$now_branch" = "$BRANCH" ] || halt halted-branch "branch drifted $BRANCH -> $now_branch during iteration $it ($ref)" 4
  [ -z "$(git status --porcelain)" ] || halt halted-dirty "dirty working tree after iteration $it ($ref) — see git status" 4

  line=$(tail -n +"$((marker + 1))" "$REPORT" | awk -v r="$ref" '$1 == r { l = $0 } END { print l }')
  status=$(printf '%s' "$line" | awk '{ print $2 }')
  log "iteration $it: reported '${line:-<no report line>}' (exit $rc)"

  if [ "$status" = closed ] && [ -n "$VERIFY_CMD" ]; then
    if timeout -k 30 "$TIMEOUT" bash -c "$VERIFY_CMD" >"$RUN_DIR/iteration-$it-verify.out" 2>&1; then
      log "iteration $it: verify passed"
    else
      log "iteration $it: reported closed but verify failed — reclassified as failed"
      status=failed-verify
    fi
  fi

  case "$status" in
    closed)
      stall=0
      outcome "$ref" closed
      continue
      ;;
    needs-review)
      outcome "$ref" needs-review
      ;;
    blocked-by)
      blocker=$(printf '%s' "$line" | awk '{ print $3 }')
      if [ -n "$blocker" ] && [ "$blocker" != "$ref" ] && [ "$splices" -lt "$SPLICE_CAP" ] \
        && ! in_list "$blocker" "$attempted" && ! in_queue "$blocker"; then
        splices=$((splices + 1))
        push_front "$blocker" "$ref"
        log "spliced $blocker ahead of $ref ($splices/$SPLICE_CAP)"
        outcome "$ref" "requeued-after $blocker"
      else
        log "not splicing '$blocker' for $ref (cap reached, already seen, or malformed)"
        outcome "$ref" "blocked-by ${blocker:-unknown}"
      fi
      ;;
    blocked)
      outcome "$ref" blocked
      ;;
    *) # failed, failed-verify, malformed, silence, or timeout
      if in_list "$ref" "$retried"; then
        log "$ref failed twice — skipping"
        outcome "$ref" "${status:-failed}"
      else
        retried="$retried $ref"
        push_front "$ref"
        log "$ref failed — retrying once"
        outcome "$ref" retrying
      fi
      ;;
  esac

  stall=$((stall + 1))
  [ "$stall" -lt "$STALL_LIMIT" ] || halt halted-stall "$stall consecutive iterations without a close" 2
done

log "run done: queue drained after $it iterations, HEAD $(git rev-parse --short HEAD)"
echo done >"$RUN_DIR/status"

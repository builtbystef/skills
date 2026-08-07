#!/usr/bin/env bash
# Starts the {{project}} agent sandbox. THIS SCRIPT RUNS ON THE HOST.
# A sandboxed agent can edit this file, and the edits run on your host the
# next time that you start it. Review `git diff -- sandbox/` before each
# start.
#
# The security flags (--cap-drop, --security-opt, the mount list) are the
# sandbox boundary. Do not weaken them. The resource limits below them only
# protect the host. Edit those freely.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"
NAME="sandbox-{{project}}"

tty_flags="-i"
[ -t 0 ] && tty_flags="-it"

exec {{runtime}} run \
  --rm $tty_flags \
  --name "$NAME" \
  --cap-drop=all \
  --security-opt=no-new-privileges \
  {{user-flag}} \
  --pids-limit=2048 \
  --memory=4g \
  --cpus=2 \
  --volume "$REPO:/workspace" \
  --volume "$NAME-home:{{container-home}}" \
  --env "GIT_AUTHOR_NAME=$(git config user.name)" \
  --env "GIT_AUTHOR_EMAIL=$(git config user.email)" \
  --env "GIT_COMMITTER_NAME=$(git config user.name)" \
  --env "GIT_COMMITTER_EMAIL=$(git config user.email)" \
  --workdir /workspace \
  "$NAME" \
  "${@:-bash}"

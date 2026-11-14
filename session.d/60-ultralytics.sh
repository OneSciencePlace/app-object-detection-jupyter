# shellcheck shell=bash
# 60-ultralytics.sh - Ultralytics' settings directory, per session. Sourced by
# app-jupyter's entrypoint at every session start (app-jupyter:
# osp/session.d/README.md).
#
# The image's YOLO_CONFIG_DIR is a fallback in /tmp (the Dockerfile). While it
# is still in effect, the session gets its own under $TMPDIR (under the run
# profile, the job directory), beside the other caches app-jupyter moves
# there; a value the job set is kept. Nothing secret is written there.
if [ "${YOLO_CONFIG_DIR:-}" = /tmp/Ultralytics ]; then
    export YOLO_CONFIG_DIR="${TMPDIR:-/tmp}/${OSP_APP_SOCK_DIR##*/}/Ultralytics"
fi

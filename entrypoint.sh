#!/bin/sh
# app-object-detection-jupyter - branch A of the interactive contract: the app
# has native URL-token auth, so it binds OSP_APP_PORT directly and there is no
# nginx gate.
#
# This is app-jupyter's entrypoint plus one step: seeding the tutorial notebook
# into the session's working directory. Everything else is byte-identical, on
# purpose -- the interactive contract is the same contract.
set -eu

# Scratch directory. The scheduler usually hands us a TMPDIR pointing at a host
# path like /scratch/$USER/job.12345 -- and Apptainer binds $HOME, /tmp and $PWD
# by default, NOT necessarily /scratch. Inside the container that path does not
# exist and the root filesystem is read-only, so `mkdir -p "$TMPDIR"` dies with
# "cannot create directory '/scratch': Read-only file system". Try the
# candidates in order and use the first one we can actually write to. Bind the
# real scratch in (`--bind /scratch`) if you want it used.
_pick_tmpdir() {
    for _d in "${TMPDIR:-}" /tmp "${HOME:-}"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_tmpdir_was="${TMPDIR:-}"
TMPDIR="$(_pick_tmpdir)" || {
    echo "[app] no writable scratch directory (tried TMPDIR, /tmp, HOME)" >&2
    exit 1
}
export TMPDIR
if [ -n "$_tmpdir_was" ] && [ "$_tmpdir_was" != "$TMPDIR" ]; then
    echo "[app] TMPDIR=$_tmpdir_was is not writable in this container; using $TMPDIR" >&2
fi

. /app/web/session-env.sh

# Every Jupyter scratch path, scoped by uid. Under Apptainer /tmp is usually
# the compute node's, shared with every other user on it, and Jupyter creates
# these directories 0700 -- so a fixed path means the second user to start this
# container cannot write to a directory the first one owns.
# ipc socket paths must fit in sockaddr_un (~107 bytes) and the longest one is
# roughly "$JUPYTER_BASE/runtime/kernel-<uuid>-ipc-N", about 58 more -- so a
# long TMPDIR falls back to /tmp even when it is perfectly writable.
_pick_jupyter_base() {
    for _d in "$TMPDIR" /tmp; do
        _b="${_d}/jupyter-$(id -u)"
        [ "${#_b}" -le 45 ] || continue
        mkdir -p "$_b" 2>/dev/null || continue
        [ -w "$_b" ] || continue
        printf '%s' "$_b"
        return 0
    done
    return 1
}
JUPYTER_BASE="$(_pick_jupyter_base)" || {
    echo "[session] no writable directory short enough for kernel ipc sockets" >&2
    exit 1
}

export JUPYTER_CONFIG_DIR="${JUPYTER_BASE}/config" \
       JUPYTER_DATA_DIR="${JUPYTER_BASE}/data" \
       JUPYTER_RUNTIME_DIR="${JUPYTER_BASE}/runtime" \
       IPYTHONDIR="${JUPYTER_BASE}/ipython"

# ---------------------------------------------------------------------------
# Seed the tutorial notebook into the session's working directory.
#
# The master copy lives at /app/notebooks/, read-only, baked in at build time
# like the model weights. It cannot be the copy the user opens: /app is inside
# the .sif, which is mounted read-only, so the first Ctrl-S would fail. Under
# Docker the working directory is ospuser's home, and a bind mount over it
# would hide anything baked there anyway.
#
# Existing files are never overwritten -- a user who edited the notebook and
# restarted the container keeps their edits.
: "${OSP_NOTEBOOK:=object_detection_tutorial.ipynb}"
: "${OSP_SEED_NOTEBOOKS:=1}"

_seed_notebooks() {
    if [ "$OSP_SEED_NOTEBOOKS" = "0" ]; then
        return 0
    fi
    if [ ! -d /app/notebooks ]; then
        return 0
    fi
    if [ ! -w . ]; then
        echo "[app] working directory $PWD is not writable; not seeding notebooks." >&2
        echo "[app] the master copies are readable at /app/notebooks/." >&2
        return 0
    fi
    for _nb in /app/notebooks/*.ipynb; do
        [ -f "$_nb" ] || continue
        _base="${_nb##*/}"
        if [ -e "./$_base" ]; then
            echo "[app] $_base is already here; keeping your copy."
        elif cp "$_nb" "./$_base" 2>/dev/null && chmod u+w "./$_base" 2>/dev/null; then
            echo "[app] seeded $_base into $PWD"
        else
            echo "[app] could not seed $_base into $PWD (open /app/notebooks/$_base instead)" >&2
        fi
    done
    return 0
}
_seed_notebooks

# Open straight into the tutorial when it is actually there. Skipped otherwise,
# because JupyterLab shows an error dialog for a default_url that 404s.
_default_url=""
if [ -f "./$OSP_NOTEBOOK" ]; then
    _default_url="--ServerApp.default_url=/lab/tree/${OSP_NOTEBOOK}"
fi

echo "[app] notebook root: $PWD"
echo "[app] model        : ${APP_MODEL:-/app/yolo11n.pt}"

# The token goes in the environment, NOT on the command line. /proc/<pid>/cmdline
# is world-readable, so `ps aux` on a shared compute node would hand the session
# to any other user on it. /proc/<pid>/environ is 0400, owner only.
export JUPYTER_TOKEN="${OSP_APP_TOKEN}"

# ServerApp.root_dir defaults to the CWD, which is what we want: Apptainer
# starts us in the user's directory and their files are simply there, and the
# notebook we just seeded is one of them.
exec jupyter lab \
    --ServerApp.ip=0.0.0.0 \
    --ServerApp.port="${OSP_APP_PORT}" \
    --ServerApp.allow_root=True \
    --ServerApp.open_browser=False \
    --ServerApp.allow_remote_access=True \
    --ServerApp.trust_xheaders=True \
    --KernelManager.transport=ipc \
    --ServerApp.terminado_settings="{'shell_command': ['/bin/bash']}" \
    ${_default_url:+"$_default_url"} \
    "$@"

# IdentityProvider.token, not ServerApp.token: the latter is deprecated since
# Jupyter Server 2.0 and warns on every start.
#
# allow_root is for `docker run` only. This image sets USER ospuser, so it is
# already a no-op unless somebody passes --user 0. Under Apptainer we are always
# the invoking user and the flag never applies.
#
# JUPYTER_TOKEN is read by jupyter_server's IdentityProvider and is exactly
# equivalent to --IdentityProvider.token, minus the process-list exposure.
#
# KernelManager.transport=ipc puts the kernel's ZMQ channels on unix sockets
# instead of TCP. Under Docker that is cosmetic -- loopback inside the
# container's own network namespace. Under Apptainer there IS no network
# namespace, so TCP kernel ports land on the compute node's real loopback,
# visible to every other user with a shell on that node. The unix sockets come
# out srwxr-xr-x, and connecting to one needs write permission, so they are
# not reachable by anyone else.
#
# trust_xheaders makes Jupyter believe Satellite's X-Forwarded-Proto: https,
# so the websocket URLs it generates come out wss:// rather than ws://.
#
# If the websocket still fails to connect, the next thing to try is relaxing
# the origin check -- Jupyter compares Origin against Host, and a proxy that
# rewrites Host will trip it:
#     --ServerApp.allow_origin='*'
# That is a real reduction in CSRF protection. The token is still required,
# but do not add it reflexively.

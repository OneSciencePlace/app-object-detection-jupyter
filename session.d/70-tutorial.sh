# shellcheck shell=bash
# 70-tutorial.sh - copy the tutorial into the session's working directory and
# open JupyterLab on it. Sourced by app-jupyter's entrypoint at every session
# start, in the working directory, before JupyterLab starts (app-jupyter:
# osp/session.d/README.md).
#
# The master copy, /app/notebooks/, is read-only: /app is inside the .sif, so
# the first Ctrl-S would fail there, and under Docker a bind mount over the
# home would hide anything baked into it. So it is copied into the working
# directory, never over an existing file: a user who edited the notebook and
# started a new session keeps their edits.
#
# OSP_NOTEBOOK: the notebook JupyterLab opens on.
# OSP_SEED_NOTEBOOKS=0: copy nothing.
: "${OSP_NOTEBOOK:=object_detection_tutorial.ipynb}"
: "${OSP_SEED_NOTEBOOKS:=1}"

if [ "$OSP_SEED_NOTEBOOKS" != 0 ] && [ -d /app/notebooks ]; then
    if [ ! -w . ]; then
        echo "[app] working directory $PWD is not writable; not copying notebooks." >&2
        echo "[app] the master copies are readable at /app/notebooks/." >&2
    else
        for _nb in /app/notebooks/*.ipynb; do
            [ -f "$_nb" ] || continue
            _base=${_nb##*/}
            if [ -e "./$_base" ]; then
                echo "[app] $_base is already here; keeping your copy."
            elif cp "$_nb" "./$_base" 2>/dev/null && chmod u+w "./$_base" 2>/dev/null; then
                echo "[app] copied $_base into $PWD"
            else
                echo "[app] could not copy $_base into $PWD (open /app/notebooks/$_base instead)" >&2
            fi
        done
    fi
fi

# Open on the tutorial only when it is really there: JupyterLab shows an error
# dialog for a default URL that does not exist. A hook cannot add to
# JupyterLab's command line, so this goes in a config file in the session's
# private config directory (the entrypoint set JUPYTER_CONFIG_DIR). It must be
# LabApp.default_url: started as jupyter-lab, JupyterLab's own default ("/lab")
# overrides a ServerApp.default_url from a config file.
if [ -f "./$OSP_NOTEBOOK" ]; then
    mkdir -p "$JUPYTER_CONFIG_DIR"
    python3 -c 'import json, sys; json.dump({"LabApp": {"default_url": "/lab/tree/" + sys.argv[1]}}, open(sys.argv[2], "w"))' \
        "$OSP_NOTEBOOK" "$JUPYTER_CONFIG_DIR/jupyter_server_config.json"
    echo "[app] JupyterLab opens on $OSP_NOTEBOOK"
fi
echo "[app] notebook root: $PWD"
echo "[app] model        : ${APP_MODEL:-/app/yolo11n.pt}"

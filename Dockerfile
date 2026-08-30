FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# libgl1/libglib2.0-0: opencv-python (a hard dependency of ultralytics) links
# against libGL. git and curl are what people expect to have inside a notebook
# session -- this image is the interactive sibling of app-object-detection.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# CPU-only torch, installed before ultralytics so that ultralytics finds its
# torch/torchvision requirement already satisfied. PyPI's default torch wheel
# for Linux is the CUDA build: ~2.5 GB in the image, and every byte of it ends
# up in the .sif that gets copied to every compute node.
#
# For a GPU demo, delete this step and change the base image to
#   FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04
# plus a python3 install -- pip will then pull the CUDA build of torch as an
# ordinary dependency of ultralytics.
RUN pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        torch==2.13.0 torchvision==0.28.0

# Everything else is installed at build time too. Nothing may be fetched at
# run time: a .sif is read-only and compute nodes are often offline.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# The container user. Created before the ENV block below so that HOME points at
# a directory that already exists during the rest of the build.
#
# 1777 rather than 0755: under `docker run --user <uid>` and under Apptainer the
# runtime uid is whatever the caller happens to be, not 1000, and the entrypoint
# has to be able to seed the tutorial notebook into this directory. The sticky
# bit keeps one user from deleting another's files on a shared image.
ARG OSP_UID=1000
RUN useradd --create-home --uid ${OSP_UID} --shell /bin/bash ospuser \
    && chmod 1777 /home/ospuser

# A .sif is mounted read-only, so every library scratch path goes to /tmp and
# the model weights are baked in at a fixed absolute path. APP_MODEL is the
# same variable app-object-detection's run.py reads, with the same default, so
# the notebook and the batch script resolve to identical weights.
ENV HOME=/home/ospuser \
    XDG_CACHE_HOME=/tmp/.cache \
    YOLO_CONFIG_DIR=/tmp/Ultralytics \
    MPLCONFIGDIR=/tmp/matplotlib \
    APP_MODEL=/app/yolo11n.pt
# The JUPYTER_* paths are NOT set here: entrypoint.sh derives them from TMPDIR
# and the runtime uid, which an ENV cannot do. See the comment there.

# Downloaded at build time into WORKDIR, i.e. /app/yolo11n.pt = $APP_MODEL.
# Swap for yolo26n.pt (newest generation) or a larger size (s/m/l/x) freely --
# the API is identical, only the weights file changes. Keep it in step with
# app-object-detection so the two produce comparable results.
RUN python -c "from ultralytics import YOLO; YOLO('yolo11n.pt')"

# Branch A of the interactive contract: JupyterLab reads ?token= natively, so
# OSP_APP_TOKEN_NAME stays `token` and there is no nginx gate in this image.
# OSP_APP_TOKEN_NAME is deliberately NOT an ENV here. Its value is a parameter
# name, not a secret, but BuildKit's SecretsUsedInArgOrEnv check matches on
# the word TOKEN and warns. web/session-env.sh already defaults it to `token`,
# so the ENV was redundant.
ENV OSP_APP_PORT=8888
EXPOSE 8888

# /etc/passwd group-writable so entrypoint can add an entry for the runtime uid
# when run as `--user "$(id -u):0"`. Harmless otherwise, and read-only under
# Apptainer, which supplies the entry itself.
RUN chmod g=u /etc/passwd /etc/group

# The read-only master copy of the tutorial. The entrypoint copies it into the
# session's working directory at startup: a notebook baked into the image can
# be opened but never saved, because the .sif filesystem is read-only and
# because a bind mount over the home directory would hide it anyway.
COPY notebooks/ /app/notebooks/
COPY web/ /app/web/
COPY entrypoint.sh /app/entrypoint.sh
# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh /app/web/session-env.sh

# The notebook root is the caller's working directory: Docker gets it from
# WORKDIR below, Apptainer from wherever the user ran the command. Under Docker
# that working directory is ospuser's home, which is where the tutorial lands.
WORKDIR /home/ospuser
USER ospuser

ENTRYPOINT ["/app/entrypoint.sh"]
# Args are appended after the entrypoint and reach `jupyter lab`, e.g.:
#   --ServerApp.allow_origin='*'

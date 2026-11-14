# app-object-detection-jupyter: app-jupyter plus the object-detection stack,
# built the way app-jupyter's README describes ("Build your own Jupyter image
# on this one"). Everything about the session -- the token gate, JupyterLab on
# a Unix socket, the session directory, the entrypoint -- comes from
# app-jupyter. This repository adds packages (requirements.txt, apt.txt), two
# session hooks (session.d/), the tutorial and the model weights.
#
# The base, pinned by tag and the OCI image's digest (the image's, not the
# .sif's). A fix in app-jupyter reaches this image when this line is bumped.
FROM ghcr.io/onescienceplace/app-jupyter:4.6.3-osp2@sha256:9450c8b323c6539a1139ab5571d58fe58882d1454cee432ce180b25d56dec668

# Ultralytics' settings directory: the image's fallback, which
# session.d/60-ultralytics.sh moves to a per-session directory at run time.
# APP_MODEL is the same variable app-object-detection's run.py reads, with the
# same default, so the notebook and the batch app resolve to identical weights.
ENV YOLO_CONFIG_DIR=/tmp/Ultralytics \
    APP_MODEL=/app/yolo11n.pt

# Packages and session hooks: requirements.txt, apt.txt, session.d/.
COPY . /tmp/osp/
RUN /app/osp/install.sh /tmp/osp

# This app's own build steps. They go between install.sh and finish-build.sh,
# which stays the last RUN line.
#
# - The weights, downloaded now into /app (= $APP_MODEL): nothing may be
#   fetched at run time, as a .sif is read-only and compute nodes are often
#   offline. Swap for yolo26n.pt or a larger size freely; keep it in step with
#   app-object-detection so the two produce comparable results.
# - The tutorial's read-only master copy, /app/notebooks/, which
#   session.d/70-tutorial.sh copies into the session's working directory.
# - The user ospuser (uid 1000), whose home is the working directory under a
#   plain `docker run`; 1777 because the runtime uid is whatever the caller
#   is (docker run --user, or anyone under Apptainer).
ARG OSP_UID=1000
RUN cd /app \
    && python3 -c "from ultralytics import YOLO; YOLO('yolo11n.pt')" \
    && test -s "$APP_MODEL" \
    && rm -rf /tmp/Ultralytics \
    && mkdir -p /app/notebooks \
    && cp /tmp/osp/notebooks/*.ipynb /app/notebooks/ \
    && chmod -R a+rX /app/notebooks "$APP_MODEL" \
    && useradd --create-home --uid "${OSP_UID}" --shell /bin/bash ospuser \
    && chmod 1777 /home/ospuser

# Last RUN line: debugpy out, the Jupyter pins, the hooks, setuid stripped.
RUN /app/osp/finish-build.sh

# After finish-build.sh only lines that run nothing. Under a plain `docker run`
# the session is ospuser in its home; under Apptainer the container is always
# the invoking user, in the directory it was started from, and these are ignored.
ENV HOME=/home/ospuser
WORKDIR /home/ospuser
USER ospuser

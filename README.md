# app-object-detection-jupyter

The interactive sibling of
[`app-object-detection`](https://github.com/OneSciencePlace/app-object-detection).
Same model, same outputs, same pipeline — but you drive it from a notebook
instead of a command line.

```
app-object-detection            app-object-detection-jupyter
run.py --image photo.jpg  ─────▶  object_detection_tutorial.ipynb
      one shot, batch                cell by cell, with a slider
              │                                │
              └────── yolo11n.pt, <stem>_detected.jpg, detections.json ──────┘
```

It is built on `app-jupyter`: **branch A** of the interactive contract, so
JupyterLab binds the single exposed port directly with its native `?token=`
auth and there is no nginx gate.

```
browser ──https──▶ Satellite ──http──▶ 0.0.0.0:OSP_APP_PORT   jupyter lab
```

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | The image. Weights baked at `/app/yolo11n.pt`; user `ospuser`, home `/home/ospuser`. |
| `requirements.txt` | Pinned Python deps — `app-jupyter`'s plus `app-object-detection`'s. |
| `notebooks/object_detection_tutorial.ipynb` | The tutorial. Read-only master copy, baked in at `/app/notebooks/`. |
| `entrypoint.sh` | The image ENTRYPOINT. Seeds the notebook, then `exec`s `jupyter lab` with `"$@"`. |
| `web/session-env.sh` | The interactive session contract. Copied verbatim from `app-jupyter`. |
| `.github/workflows/build-and-push.yml` | Build + push both artifacts. App-agnostic — copy as-is. |

## Run it

```bash
TOKEN=$(openssl rand -hex 32)

docker run --rm --user "$(id -u):$(id -g)" \
  -p 8888:8888 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=8888 -e OSP_APP_TOKEN="$TOKEN" \
  ghcr.io/onescienceplace/app-object-detection-jupyter:latest

apptainer pull oras://ghcr.io/onescienceplace/app-object-detection-jupyter-sif:latest
apptainer run --env OSP_APP_PORT=8888 --env OSP_APP_TOKEN="$TOKEN" \
  app-object-detection-jupyter-sif_latest.sif
```

Then open `https://<session>.<satellite-domain>/?token=$TOKEN`. JupyterLab opens
on the tutorial notebook directly.

The container prints its port and entry path on startup, which is what the job
script needs to register the mapping with Satellite. Put a JPEG in the directory
you mounted (or upload one from inside the notebook) and run the cells.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `8888` | the single port served |
| `OSP_APP_TOKEN` | generated | per-session secret; JupyterLab's own `?token=` |
| `OSP_APP_TOKEN_NAME` | `token` | fixed here — it is Jupyter's own parameter name |
| `APP_MODEL` | `/app/yolo11n.pt` | the baked-in weights; same variable `run.py` reads |
| `OSP_NOTEBOOK` | `object_detection_tutorial.ipynb` | the notebook JupyterLab opens on |
| `OSP_SEED_NOTEBOOKS` | `1` | set `0` to skip seeding entirely |

## `ospuser`, and where the notebook lives

The image declares `USER ospuser` with home `/home/ospuser`, and that home is
the `WORKDIR`. So a plain `docker run` lands the session in a real user's home
directory with a real `/etc/passwd` entry — `whoami` works, `ls -l` shows names,
and nothing runs as root.

Under Apptainer none of that applies: the container is always the invoking user
and the image's `WORKDIR` is ignored in favour of the directory you ran from.
Both cases end up in the same place conceptually — **the session's working
directory** — which is also where `run.py` reads and writes. That symmetry is
the point: a path that works in the notebook works in the batch app.

`/home/ospuser` is mode `1777`, not `0755`, because the runtime uid is whatever
the caller happens to be (`docker run --user`, or any user at all under
Apptainer) and the entrypoint has to be able to write into it.

### Why the notebook is copied instead of just opened

The master copy is baked in at `/app/notebooks/`, read-only, exactly like the
model weights. It cannot be the file you open:

- `/app` lives inside the `.sif`, which is mounted **read-only**. The first
  Ctrl-S would fail.
- A bind mount over the home directory would hide anything baked there anyway.

So `entrypoint.sh` copies it into the working directory at startup. It **never
overwrites an existing file** — restart the container and your edits survive.
If the working directory is not writable it says so on stderr and leaves the
read-only master where you can still open it.

Anything you write lands next to the notebook. Under Docker that survives the
container only if you bind-mounted the directory; under Apptainer it is your own
directory already.

## Consistency with the batch app

The notebook is a re-expression of `run.py`, not a reimplementation. Deliberately
identical:

| | both |
|---|---|
| Weights | `yolo11n.pt`, baked in at build time, resolved through `APP_MODEL` |
| Input | a path relative to the current working directory |
| Annotated image | `<stem>_detected.jpg`, from `result.plot()`, written with `cv2.imwrite` |
| Structured output | `detections.json` — `{image, count, detections[{class, confidence, bbox_xyxy}]}` |
| Rounding | confidence to 4 dp, bbox to 1 dp |
| Default threshold | `0.25` |

Anything downstream that consumes the batch app's output consumes the
notebook's without knowing which produced it. The intended workflow is to find
a confidence threshold interactively here, then pass it to the batch app as
`--conf` for the whole dataset.

What the notebook adds is the part a one-shot entrypoint cannot show: a slider
that reruns `model.predict` at a new threshold, so you see the effect of
`--conf` rather than reasoning about it.

## Kernels and scratch paths

Inherited unchanged from `app-jupyter`, and the reasoning there applies verbatim:

The token is passed as `JUPYTER_TOKEN` in the environment, never as a command
line argument — `/proc/<pid>/cmdline` is world-readable, so `ps aux` on a shared
node would otherwise hand the session to anyone there.

Kernels run over **unix sockets, not TCP** (`--KernelManager.transport=ipc`).
Apptainer has no network namespace, so TCP kernel ports would land on the
compute node's real loopback, visible to every other user with a shell there.

`JUPYTER_CONFIG_DIR`, `JUPYTER_DATA_DIR`, `JUPYTER_RUNTIME_DIR` and `IPYTHONDIR`
are derived at startup from `$TMPDIR` and the runtime uid
(`$TMPDIR/jupyter-$(id -u)/…`), because Jupyter creates them `0700` and `/tmp`
is shared with every other user on the node. One consequence: the
notebook-signing key is regenerated every session, so notebook *trust* does not
persist and saved HTML/JS output needs a re-run to render.

The library caches go to `/tmp` for the same read-only-filesystem reason as the
batch app: `XDG_CACHE_HOME`, `YOLO_CONFIG_DIR`, `MPLCONFIGDIR`.

**Scratch paths.** The entrypoint does not trust `$TMPDIR`. A scheduler's
`/scratch/$USER/job.N` is a host path Apptainer does not bind by default, so it
probes `$TMPDIR`, `/tmp`, `$HOME` in turn and reports on stderr which it took.
Pass `--bind /scratch` if you want the real one used.

`--ServerApp.trust_xheaders` is the one thing that matters for running behind
Satellite: TLS is terminated upstream, and without it Jupyter builds `ws://`
websocket URLs on an `https://` page and the browser refuses them.

## Pinned versions

| What | Version | Where |
|---|---|---|
| Base image | `python:3.14-slim` | `Dockerfile` |
| JupyterLab | `4.6.3` | `requirements.txt` |
| ipywidgets | `8.1.9` | `requirements.txt` |
| Ultralytics | `8.4.131` | `requirements.txt` |
| torch / torchvision | `2.13.0` / `0.28.0`, CPU-only | `Dockerfile` |
| Model weights | `yolo11n.pt` | baked in at build time |
| Apptainer | `1.5.2` | `APPTAINER_VERSION` in the workflow |
| Actions | checkout v6, buildx v4, login v4, metadata v6, build-push v7 | the workflow |

The Python pins are held in step with `app-object-detection` and `app-jupyter`
on purpose. Bump them together, or the two halves stop being comparable.

The image is CPU-only: PyPI's default torch wheel is the CUDA build, which adds
roughly 2 GB the `.sif` then carries to every compute node. The Dockerfile
installs torch from PyTorch's CPU index first; the GPU route is one commented
block away.

## Build and test locally

Skip GitHub and the registry entirely:

```bash
docker build -t app-object-detection-jupyter:dev .   # --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -p 8888:8888 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=8888 -e OSP_APP_TOKEN=localdev app-object-detection-jupyter:dev

docker save app-object-detection-jupyter:dev -o aodj.tar
apptainer build aodj.sif docker-archive://aodj.tar
apptainer run --env OSP_APP_PORT=8888 --env OSP_APP_TOKEN=localdev aodj.sif
```

Open `http://localhost:8888/?token=localdev`. Locally there is no proxy in
front, so this is plain http and the URL keeps its token — under Satellite the
scheme is https and the entry path is otherwise identical.

Two things worth checking that only the `.sif` exercises: that the notebook was
seeded into your directory rather than opened read-only out of `/app`, and that
`model.predict` runs without reaching the network. Both are the read-only /
offline rules, and both pass under `docker run` regardless.

### Why `--user`

The image already sets `USER ospuser` (uid 1000), so a bare `docker run` does
not write root-owned files. But uid 1000 is probably not *you*: on Linux,
anything the container writes into a bind mount still comes out owned by 1000,
and if the mounted directory is yours the container may not be able to write to
it at all. `--user "$(id -u):$(id -g)"` fixes both and matches how Apptainer
runs it — Apptainer is always the invoking user.

To reclaim files a previous run left behind:

```bash
sudo chown -R "$(id -u):$(id -g)" .
```

That uid has no `/etc/passwd` entry inside the container, so `whoami` fails and
`ls -l` shows bare numbers. Nothing actually breaks — only code calling
`getpwuid()` notices — and Apptainer generates the entry itself, so this never
shows up in production. If you want a name locally:

```bash
# 1. Let the entrypoint add one. /etc/passwd is group-writable in this image,
#    so running with group 0 is enough. You become `ospuser`.
docker run --rm --user "$(id -u):0" ...

# 2. Or show the container your real identity, keeping your own gid.
docker run --rm --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro ...
```

Set `OSP_APP_USER` to change the name option 1 uses.

`apptainer build` from a local archive needs no root and no fakeroot. Test the
`.sif` and not just the image: read-only-filesystem bugs never show up under
`docker run`.

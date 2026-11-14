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

It is built `FROM` the `app-jupyter` image, the way app-jupyter's README
describes ("Build your own Jupyter image on this one"): JupyterLab behind the
token gate, like every interactive app, with this repository adding only
packages, two session hooks, the tutorial and the model. The gate is the
session's one TCP listener and checks its token; JupyterLab listens on a Unix
socket in the session's private directory.

```
browser ──https──▶ Satellite proxy ──ssh tunnel──▶ $OSP_APP_BIND:$OSP_APP_PORT   nginx gate
                                                    (127.0.0.1 by default)       │ cookie / 403
                                                                                 ▼
                                                  $OSP_APP_SOCK_DIR/app.sock     jupyter lab
```

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM app-jupyter`, pinned by tag and digest; `install.sh`, this app's build steps (weights baked at `/app/yolo11n.pt`, the tutorial at `/app/notebooks/`, user `ospuser` with home `/home/ospuser`), `finish-build.sh` last. |
| `requirements.txt` | Pinned Python packages, `app-object-detection`'s: CPU-only torch from PyTorch's index, ipywidgets, Ultralytics. JupyterLab comes from `app-jupyter`, held at its versions. |
| `apt.txt` | System libraries opencv needs (`libgl1`, `libglib2.0-0`). |
| `session.d/60-ultralytics.sh` | Session hook: Ultralytics' settings directory per session. |
| `session.d/70-tutorial.sh` | Session hook: copies the tutorial into the working directory and opens JupyterLab on it. |
| `notebooks/object_detection_tutorial.ipynb` | The tutorial. Read-only master copy, baked in at `/app/notebooks/`. |
| (from `app-jupyter`) | The entrypoint, the session files (gate, supervisor), the build tools (`/app/osp/install.sh`, `finish-build.sh`) and the Dask and Ray hooks, which do nothing here. |
| `.github/workflows/build-and-push.yml` | Build + push both artifacts. App-agnostic — copy as-is. |

## Run it

The token is never put on a command line: `ps` shows command lines to every
user on a node. Pass it through the environment.

```bash
export OSP_APP_TOKEN=$(openssl rand -hex 32)

# Docker (local). -e OSP_APP_TOKEN with no "=value" copies it from your
# environment. OSP_APP_BIND=0.0.0.0 because `-p` cannot reach a container's
# loopback; the host side is still published on 127.0.0.1 only.
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:8888:8888 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=8888 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  ghcr.io/onescienceplace/app-object-detection-jupyter:latest

# Apptainer, under the OSP interactive run profile.
# APPTAINERENV_<NAME> reaches the container as <NAME>, even with --cleanenv
# (SingularityCE: SINGULARITYENV_<NAME>).
apptainer pull oras://ghcr.io/onescienceplace/app-object-detection-jupyter-sif:latest   # production pins <version>@sha256:<digest>
mkdir -p tmp
export APPTAINERENV_OSP_APP_TOKEN="$OSP_APP_TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=8888 --env TMPDIR="$PWD/tmp" \
  app-object-detection-jupyter-sif_latest.sif
```

Then open `http://127.0.0.1:8888/?token=<the token>` (add an
`ssh -L 8888:127.0.0.1:8888 <host>` forward first if it runs elsewhere).
Through the portal the link is
`https://<session-label>.<sat-id>.sat.<domain>/?token=<token>`, handed out by
the launcher once the gate's `/healthz` answers. JupyterLab opens on the
tutorial notebook directly.

The container prints its port on startup, and the entry path without the
token when the launcher supplied it. Put a JPEG in the working directory (or upload
one from inside the notebook) and run the cells.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `8888` | the one TCP port, served by the gate |
| `OSP_APP_BIND` | `127.0.0.1` | the address it binds; `0.0.0.0` only inside a Docker job's own network, or for local `docker run -p` |
| `OSP_APP_TOKEN` | generated | per-session secret, checked by the gate |
| `OSP_APP_TOKEN_NAME` | `token` | the query parameter (and cookie) it arrives in |
| `APP_MODEL` | `/app/yolo11n.pt` | the baked-in weights; same variable `run.py` reads |
| `OSP_NOTEBOOK` | `object_detection_tutorial.ipynb` | the notebook JupyterLab opens on (`session.d/70-tutorial.sh`) |
| `OSP_SEED_NOTEBOOKS` | `1` | set `0` to copy no notebooks (`session.d/70-tutorial.sh`) |

## `ospuser`, and where the notebook lives

The image declares `USER ospuser` with home `/home/ospuser`, and that home is
the `WORKDIR`. So a plain `docker run` lands the session in a real user's home
directory with a real `/etc/passwd` entry — `whoami` works, `ls -l` shows names,
and nothing runs as root.

Under Apptainer none of that applies: the container is always the invoking user
and the image's `WORKDIR` is ignored in favor of the directory you ran from (the job
directory, under the run profile, where `$HOME` is also a private, empty
directory for the session).
Both cases end up in the same place conceptually — **the session's working
directory** — which is also where `run.py` reads and writes. That symmetry is
the point: a path that works in the notebook works in the batch app.

`/home/ospuser` is mode `1777`, not `0755`, because the runtime uid is whatever
the caller happens to be (`docker run --user`, or any user at all under
Apptainer) and the tutorial hook has to be able to copy the notebook into it.

### Why the notebook is copied instead of just opened

The master copy is baked in at `/app/notebooks/`, read-only, exactly like the
model weights. It cannot be the file you open:

- `/app` lives inside the `.sif`, which is mounted **read-only**. The first
  Ctrl-S would fail.
- A bind mount over the home directory would hide anything baked there anyway.

So the session hook `session.d/70-tutorial.sh` copies it into the working
directory at every session start, before JupyterLab starts, and points
JupyterLab at it (`LabApp.default_url`, in a config file in the session's
private config directory). It **never overwrites an existing file** — start a
new session and your edits survive.
If the working directory is not writable it says so on stderr and leaves the
read-only master where you can still open it.

Anything you write lands next to the notebook. Under Docker that survives the
container only if you bind-mounted the directory; under Apptainer it is the job
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

## Kernels, the session directory and scratch paths

Inherited unchanged from `app-jupyter` (the image this one is built on), whose
README has the reasoning:

- JupyterLab sits behind the gate on a Unix socket, with its own token off and
  without `OSP_APP_TOKEN` in its environment: only the gate holds the
  session's secret. **File > Shut Down** ends the session with status 0.
- Kernels run over **Unix sockets, not TCP** (`--KernelManager.transport=ipc`).
- `JUPYTER_CONFIG_DIR`, `JUPYTER_DATA_DIR`, `JUPYTER_RUNTIME_DIR` and
  `IPYTHONDIR` live in the session's private directory,
  `$OSP_APP_SOCK_DIR/jupyter/…`: the runtime directory holds the kernel
  connection files and sockets. The notebook-signing key is therefore
  regenerated every session, so notebook *trust* does not persist.
- **No debugger**: the image removes `debugpy`, whose debug server would keep
  listening on the node's loopback, unauthenticated, after the debugger is
  turned off.
- One loopback listener remains, each kernel's pipe for output from forked
  subprocesses; it acts only on messages carrying a random per-kernel key.
- `--ServerApp.trust_xheaders` and `--ServerApp.allow_remote_access` make it
  work behind the Satellite proxy.

The library caches (`XDG_CACHE_HOME`, `YOLO_CONFIG_DIR`, `MPLCONFIGDIR`)
default to `/tmp` in the image, for the same read-only-filesystem reason as the
batch app; at run time each moves to a per-session directory under `$TMPDIR`
(`<job directory>/tmp` under the run profile), unless the job set its own:
`app-jupyter` moves the first and last, and this image's hook
`session.d/60-ultralytics.sh` moves `YOLO_CONFIG_DIR`.

**Built by `app-jupyter`'s tools.** `install.sh` installed `apt.txt` and
`requirements.txt` with JupyterLab, Jupyter Server and the kernel held at
`app-jupyter`'s versions, and added the two hooks; `finish-build.sh`, the last
`RUN` line, removed `debugpy`, checked the image and stripped setuid and setgid
bits. Nothing in this image starts a server from a notebook unless the user's
code does (`torch.distributed`, for instance): the residual risk app-jupyter's
`osp/session.d/README.md` describes.

**Scratch paths.** The entrypoint does not trust an inherited `$TMPDIR`. A
scheduler's `/scratch/$USER/job.N` is a host path Apptainer may not bind, so it
probes `$TMPDIR`, `/tmp`, `$HOME` in turn and reports on stderr which it took.
Do not bind a scratch parent (`--bind /scratch`) to make it work: that shows
the container every other job directory of the account.

## Pinned versions

| What | Version | Where |
|---|---|---|
| Base image | `app-jupyter:4.6.3-osp2` (Python 3.14, JupyterLab 4.6.3, the kit's session files) | `Dockerfile` |
| ipywidgets | `8.1.9` | `requirements.txt` |
| Ultralytics | `8.4.131` | `requirements.txt` |
| torch / torchvision | `2.13.0+cpu` / `0.28.0+cpu`, CPU-only | `requirements.txt` |
| Model weights | `yolo11n.pt` | baked in at build time |
| Apptainer | `1.5.2` | `APPTAINER_VERSION` in the workflow |
| Actions | checkout v6, buildx v4, login v4, metadata v6, build-push v7 | the workflow |

The Python pins are held in step with `app-object-detection` on purpose. Bump
them together, or the two halves stop being comparable. JupyterLab moves only
when the `FROM` line moves to a newer `app-jupyter`.

The image is CPU-only: PyPI's default torch wheel is the CUDA build, which adds
roughly 2 GB the `.sif` then carries to every compute node. `requirements.txt`
takes torch from PyTorch's CPU index (`--extra-index-url`, and the `+cpu`
versions only that index has). For a GPU image, drop those three lines for the
plain `torch` / `torchvision` pins; the base would then also need CUDA's
runtime, which `app-jupyter` does not have.

## Build and test locally

Skip GitHub and the registry for the image itself (the build pulls its base,
`ghcr.io/onescienceplace/app-jupyter`, named in the `Dockerfile`; on Apple
Silicon a session cannot start under emulation, see app-jupyter's README):

```bash
docker build -t app-object-detection-jupyter:dev .   # --platform linux/amd64 on Apple Silicon
export OSP_APP_TOKEN=$(openssl rand -hex 32)
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:8888:8888 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=8888 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  app-object-detection-jupyter:dev

docker save app-object-detection-jupyter:dev -o aodj.tar
apptainer build aodj.sif docker-archive://aodj.tar
mkdir -p tmp
export APPTAINERENV_OSP_APP_TOKEN="$OSP_APP_TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=8888 --env TMPDIR="$PWD/tmp" aodj.sif
```

Open `http://127.0.0.1:8888/?token=<the token>`. Locally there is no proxy in
front, so this is plain http and the URL keeps its token — through the
Satellite proxy the scheme is https and the entry path is otherwise identical.

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

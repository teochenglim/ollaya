# ollaya — container + Helm packaging

Lean container images and a Helm chart for [Ollaya](https://github.com/ollaya-dev/ollaya)
("Ollama for decision models"), published from this repo with GitHub Actions.

> **Unofficial packaging.** The Ollaya software is © its authors, Apache-2.0. This repo does not
> compile it: the image downloads the upstream
> [release](https://github.com/ollaya-dev/ollaya/releases) tarball, **verifies its sha256**, and
> unpacks it onto `debian:trixie-slim`. Each model keeps its own license.

- [Docker](#docker) · [Helm](#helm) · [Hugging Face token](#hugging-face-token-hf_token) ·
  [Use it from agents (the skill)](#use-it-from-agents-the-ollaya-decisions-skill) ·
  [Maintaining / publishing](#maintaining--publishing)

## Docker

| Tag | Contents | Arch | Host requirement |
|---|---|---|---|
| `latest`, `cpu`, `0.18.0`, `0.18.0-cpu` | CPU only (smallest) | amd64, arm64 | none |
| `cuda`, `0.18.0-cuda` | NVIDIA, CUDA 13 | amd64, arm64 | driver R580+ |
| `cuda12`, `0.18.0-cuda12` | NVIDIA, CUDA 12 | amd64 | driver R525+ |

Moving tags (`cpu`, `cuda`, `cuda12`, `latest`) follow the newest release. Pin `X.Y.Z-<variant>`
in production.

```sh
# CPU
docker run -it --rm -p 11435:11435 -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya:latest

# NVIDIA GPU (needs the NVIDIA Container Toolkit)
docker run -it --rm --gpus all -p 11435:11435 -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya:cuda
```

Then, in another terminal:

```sh
curl http://127.0.0.1:11435/                                   # "Ollaya is running"
docker exec <container> ollaya pull laya                       # CPU-friendly router model
curl -s http://127.0.0.1:11435/v1/systemone -H 'Content-Type: application/json' \
  -d '{"model":"laya","state":"I was charged twice","questions":{"angry":{"type":"noul"}}}'
```

Notes
- Ollaya's port is **11435** (not 8080). Models live in the `/home/ollaya/.ollaya` volume, so
  mount one or you re-download on every start.
- Runs as non-root UID 1000. For a bind mount: `chown 1000:1000 ./data`.
- Env vars: [full list](https://github.com/ollaya-dev/ollaya/blob/main/docs/api.md) — e.g.
  `OLLAYA_PRELOAD=laya:en`, `OLLAYA_API_KEY`, `OLLAYA_READ_ONLY=1`, `OLLAYA_DEVICE=cpu|cuda`.
- Don't expose the port publicly without `OLLAYA_API_KEY` (clients send `Authorization: Bearer …`).

### docker compose

```yaml
services:
  ollaya:
    image: ghcr.io/teochenglim/ollaya:0.18.0-cpu
    ports: ["127.0.0.1:11435:11435"]
    volumes: [ollaya:/home/ollaya/.ollaya]
    environment:
      OLLAYA_PRELOAD: laya:en
      OLLAYA_HF_TOKEN: ${HF_TOKEN:-}   # optional, see below
    # GPU: image :0.18.0-cuda plus
    # deploy: {resources: {reservations: {devices: [{driver: nvidia, count: all, capabilities: [gpu]}]}}}
volumes:
  ollaya:
```

### Build locally

```sh
docker build -t ollaya .                                       # CPU
docker build --build-arg VARIANT=cuda -t ollaya:cuda .         # or cuda12
docker build --build-arg OLLAYA_VERSION=0.18.0 -t ollaya .     # pick the upstream release
```

## Helm

```sh
# Classic repo (GitHub Pages)
helm repo add ollaya https://teochenglim.github.io/ollaya
helm repo update
helm install ollaya ollaya/ollaya

# or OCI (no repo add)
helm install ollaya oci://ghcr.io/teochenglim/charts/ollaya --version 0.1.1
```

```sh
kubectl port-forward svc/ollaya 11435:11435
kubectl exec deploy/ollaya -- ollaya pull laya
```

Common installs:

```sh
# GPU (needs NVIDIA device plugin / GPU Operator); picks the :<ver>-cuda image + nvidia.com/gpu limit
helm install ollaya ollaya/ollaya --set gpu.enabled=true            # gpu.variant=cuda12 for older drivers

# Warm models at start, API key from an existing Secret, bigger volume
helm install ollaya ollaya/ollaya \
  --set ollaya.preload="laya:en\,laya:multilingual" \
  --set apiKey.existingSecret=ollaya-api \
  --set persistence.size=50Gi
```

The chart runs one replica (`Recreate`) because the model store is a ReadWriteOnce PVC, which is
kept on `helm uninstall` so models aren't re-downloaded. With `ollaya.preload` set, readiness uses
`/api/ready` (waits for those models to load); otherwise it uses `/`. See [values.yaml](charts/ollaya/values.yaml) for every option
(ingress, resources, tolerations, extra env …).

## Hugging Face token (`HF_TOKEN`)

Public models need **no token**. Set one only for private/gated weights (or to avoid rate limits).
Ollaya reads `OLLAYA_HF_TOKEN`, and falls back to `HF_TOKEN`. It sends the token **only to
huggingface.co** (never to a mirror set via `OLLAYA_HF_ENDPOINT`, never to the ollaya.dev
registry). `OLLAYA_HF_TOKEN` is preferred: with a mirror, `HF_TOKEN` is not forwarded to it.

The token is never baked into an image; it is only supplied at run time:

```sh
# Docker: forward from your shell without putting it on the command line
export OLLAYA_HF_TOKEN=hf_xxx
docker run -e OLLAYA_HF_TOKEN -p 11435:11435 -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya:latest

# Kubernetes (recommended): existing Secret
kubectl create secret generic ollaya-hf --from-literal=token=hf_xxx
helm install ollaya ollaya/ollaya --set huggingface.existingSecret=ollaya-hf

# Kubernetes (convenience): chart creates the Secret. The value is stored in Helm release state.
helm install ollaya ollaya/ollaya --set huggingface.token=hf_xxx
```

Tip: after the models are pulled once, run with `OLLAYA_READ_ONLY=1` (`--set ollaya.readOnly=true`)
and drop the token entirely.

## Use it from agents: the `ollaya-decisions` skill

Upstream ships an agent skill,
[`ollaya-decisions`](https://github.com/ollaya-dev/ollaya/tree/main/skills/ollaya-decisions),
that teaches an agent (Claude Code, Cursor, …) *when* to use typed decisions (classify, score,
yes/no gates) and *how* to call them, instead of burning tokens reasoning in text. The skill tries
**MCP → CLI → HTTP** in that order, so you need the skill plus one reachable Ollaya.

**1. Install the skill**

```sh
npx skills add ollaya-dev/ollaya --skill ollaya-decisions
```

**2. Point the agent at your container or cluster** (pick one)

| How | Command |
|---|---|
| **HTTP** to Docker (simplest) | `docker run -d -p 127.0.0.1:11435:11435 -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya` then `docker exec <c> ollaya pull laya`. The skill's `curl http://127.0.0.1:11435/v1/systemone …` calls just work. |
| **HTTP** to Kubernetes | `kubectl port-forward svc/ollaya 11435:11435` (or an Ingress + `OLLAYA_API_KEY`). |
| **MCP** (`decide` tool) | `claude mcp add ollaya -- docker run -i --rm -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya:latest mcp` |

Check it works: ask your agent to "triage this message with ollaya" — it should call the `decide`
tool (or `ollaya run laya --preset triage …`). Models must be pulled first
(`ollaya pull laya`), or `OLLAYA_PRELOAD=laya:en` on the server.

> The MCP-over-`docker run` line starts a *separate* server inside that one-off container. If you
> already run a long-lived server and want `ollaya mcp` to use it, install the binary locally
> (`curl -fsSL https://ollaya.dev/install.sh | sh`) and set `OLLAYA_HOST=<host>:11435`
> (plus `OLLAYA_API_KEY` if enabled). Upstream documents `OLLAYA_HOST` as the client's target;
> verify `ollaya mcp` honours it in your version.

## Maintaining / publishing

Workflows (all actions are pinned to commit SHAs):

| Workflow | Trigger | Does |
|---|---|---|
| [ci.yml](.github/workflows/ci.yml) | PR / push to `main` | hadolint, builds the CPU image (checks upstream sha256), starts it and waits for healthy, `helm lint` + renders every mode |
| [docker.yml](.github/workflows/docker.yml) | tag `vX.Y.Z` or manual | builds `cpu`/`cuda`/`cuda12` per-arch on native runners, merges into multi-arch tags on GHCR |
| [helm.yml](.github/workflows/helm.yml) | push to `main` touching `charts/**` | publishes the chart to GitHub Pages **and** `oci://ghcr.io/teochenglim/charts` |

### One-time setup

```sh
git remote add origin git@github.com:teochenglim/ollaya.git   # already set
# Pages helm repo needs an (empty) gh-pages branch:
git switch --orphan gh-pages && git commit --allow-empty -m "init pages" && git push -u origin gh-pages
git switch main
```

Then in GitHub: **Settings → Pages** → source `gh-pages` branch. After the first image publish,
**Packages → ollaya → Package settings → Change visibility → Public**, and link it to this repo
(same for the `charts/ollaya` package). Anonymous `docker pull` / `helm install` fails until then.
Under **Settings → Actions → General**, workflow permissions must allow read & write.

### Release a new upstream version

```sh
# 1. bump chart appVersion (and Chart.yaml `version`), and the Dockerfile default OLLAYA_VERSION
# 2. commit, push to main (publishes the chart), then:
git tag v0.19.0 && git push origin v0.19.0     # publishes the images
```

Or run **Actions → Publish image to GHCR → Run workflow** with a version, without a tag.
The tag's `X.Y.Z` must match an existing upstream release (`ollaya-dev/ollaya`).

## License

Packaging files: Apache-2.0 (same as upstream). Ollaya itself and each model keep their own
licenses; the image includes upstream's `LICENSE` and third-party notices under
`/usr/share/doc/ollaya`.

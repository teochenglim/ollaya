# ollaya — container + Helm packaging

Lean container images and a Helm chart for [Ollaya](https://github.com/ollaya-dev/ollaya)
("Ollama for decision models"), published from this repo with GitHub Actions.

> **Unofficial packaging.** The Ollaya software is © its authors, Apache-2.0. This repo does not
> compile it: the image downloads the upstream
> [release](https://github.com/ollaya-dev/ollaya/releases) tarball, **verifies its sha256**, and
> unpacks it onto `debian:trixie-slim`. Each model keeps its own license.

[Docker](#docker) · [Helm](#helm) · [Test it](#test-it-3-curls) · [Switching models & storage](#switching-models-and-storage) ·
[Agents (the skill)](#use-it-from-agents-the-ollaya-decisions-skill) · [Contributing](CONTRIBUTING.md)

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
docker run -d --name ollaya -p 11435:11435 -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya:latest

# NVIDIA GPU (needs the NVIDIA Container Toolkit)
docker run -d --name ollaya --gpus all -p 11435:11435 -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya:cuda

docker exec ollaya ollaya pull laya        # CPU-friendly router model (~850 MB)
```

Notes
- Ollaya's port is **11435** (not 8080). Models live in the `/home/ollaya/.ollaya` volume, so
  mount one or you re-download on every start.
- Runs as non-root UID 1000. For a bind mount: `chown 1000:1000 ./data`.
- Env vars: [full list](https://github.com/ollaya-dev/ollaya/blob/main/docs/api.md), e.g.
  `OLLAYA_PRELOAD=laya:en`, `OLLAYA_API_KEY`, `OLLAYA_READ_ONLY=1`, `OLLAYA_DEVICE=cpu|cuda`.
- Don't expose the port publicly without `OLLAYA_API_KEY` (clients send `Authorization: Bearer …`).
- Public models need no Hugging Face token. For a private/gated model, pass
  `-e OLLAYA_HF_TOKEN` (or `HF_TOKEN`) at run time; never bake it into an image.

### docker compose

```yaml
services:
  ollaya:
    image: ghcr.io/teochenglim/ollaya:0.18.0-cpu
    ports: ["127.0.0.1:11435:11435"]
    volumes: [ollaya:/home/ollaya/.ollaya]
    environment:
      OLLAYA_PRELOAD: laya:en
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
helm install ollaya oci://ghcr.io/teochenglim/charts/ollaya --version 0.1.3
```

The default install pulls `laya` into the volume on first start (init container), then serves.

```sh
kubectl port-forward svc/ollaya 11435:11435      # or expose a NodePort, below
```

Common installs:

```sh
# Reachable from outside the cluster on a NodePort
helm install ollaya ollaya/ollaya --set service.type=NodePort --set service.nodePort=30808

# GPU (needs NVIDIA device plugin / GPU Operator): picks the :<ver>-cuda image + nvidia.com/gpu limit
helm install ollaya ollaya/ollaya --set gpu.enabled=true            # gpu.variant=cuda12 for older drivers

# API key from an existing Secret (recommended if reachable by anyone else)
kubectl create secret generic ollaya-api --from-literal=key=change-me
helm install ollaya ollaya/ollaya --set apiKey.existingSecret=ollaya-api
```

Every option (ingress, resources, tolerations, extra env …) is in
[values.yaml](charts/ollaya/values.yaml).

## Test it (3 curls)

Use `http://127.0.0.1:11435` for Docker or a port-forward, or `http://<node-ip>:30808` for the
NodePort example. If you set an API key, add `-H 'Authorization: Bearer <key>'`.

```sh
H=http://127.0.0.1:11435
B='{"model":"laya","state":"I was charged twice and want a refund now!","questions":{"urgent":{"type":"noul"}}}'

# 1. TypeSafe-compatible "System One" decision
curl -s $H/v1/systemone -H 'Content-Type: application/json' -d "$B"

# 2. Alias of the above
curl -s $H/v1/decisions -H 'Content-Type: application/json' -d "$B"

# 3. List the models on this server (GET, no body)
curl -s $H/v1/models
```

The decisions return a calibrated answer per question, e.g.
`{"model":"laya:en","answers":{"urgent":{"type":"noul","noul":0.92}},…}` (`noul` is the
probability the statement is true). `/v1/models` is empty until a model is pulled. Liveness:
`curl $H/` → `Ollaya is running`. (Ollaya's native endpoint is `POST /api/decide`, same body.)

With a checkout of this repo, `make` lists one test per question type, so you can run just one:
`make test-noul` (yes/no), `make test-score` (rating), `make test-choice` (pick one),
`make test-decisions`, `make test-models`, or `make test` for all of them
(`HOST=… NODEPORT=… API_KEY=…` to point it elsewhere).

## Switching models and storage

Ollaya serves **many models from one server**. Each request names its model (`"model":"…"`);
models load on demand and unload after `keep_alive` (default 5 min). `OLLAYA_MAX_LOADED_MODELS`
(default 3) caps how many sit in RAM at once. No restart or redeploy is needed to use another model.

| Do this | Docker | Helm |
|---|---|---|
| Add a model | `docker exec ollaya ollaya pull winnow:e4b` | edit `ollaya.models` and `helm upgrade` (init container pulls what's missing), or `kubectl exec deploy/ollaya -- ollaya pull …` |
| List / remove | `ollaya ls` / `ollaya rm <m>` (`DELETE /api/delete`) | same, via `kubectl exec` |
| Keep one hot | `-e OLLAYA_PRELOAD=laya:en` | `--set ollaya.preload=laya:en` |
| Lock after seeding | `-e OLLAYA_READ_ONLY=1` | `--set ollaya.readOnly=true` |

Storage and memory (Kubernetes):
- The PVC holds **every model you keep**: `laya:en` is ~0.85 GB, others run 3–8 GB each. Default
  is `20Gi`; set `persistence.size` for your list. Shrinking later isn't supported by most CSI drivers.
- It's `ReadWriteOnce`, so the chart runs **one replica** (`Recreate` strategy). It is **kept on
  `helm uninstall`** so models aren't re-downloaded; delete it yourself to reclaim space.
- Memory limit must fit your biggest model × models loaded at once (default `8Gi`); too low means
  the pod is OOM-killed on load. Set `resources.limits.memory`.
- Without persistence (`persistence.enabled=false`) models live in an `emptyDir` and re-download
  on every pod restart.

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
| **HTTP** to Docker (simplest) | run the container as above and `ollaya pull laya`. The skill's `curl http://127.0.0.1:11435/v1/systemone …` calls just work. |
| **HTTP** to Kubernetes | `kubectl port-forward svc/ollaya 11435:11435`, or a NodePort/Ingress with `OLLAYA_API_KEY`. |
| **MCP** (`decide` tool) | `claude mcp add ollaya -- docker run -i --rm -v ollaya:/home/ollaya/.ollaya ghcr.io/teochenglim/ollaya:latest mcp` |

Check it works: ask your agent to "triage this message with ollaya". It should call the `decide`
tool (or `ollaya run laya --preset triage …`). Models must be pulled first.

> The MCP-over-`docker run` line starts a *separate* server inside that one-off container. If you
> already run a long-lived server and want `ollaya mcp` to use it, install the binary locally
> (`curl -fsSL https://ollaya.dev/install.sh | sh`) and set `OLLAYA_HOST=<host>:11435`
> (plus `OLLAYA_API_KEY` if enabled). Upstream documents `OLLAYA_HOST` as the client's target;
> verify `ollaya mcp` honours it in your version.

## Contributing / releasing

Maintainer docs (CI, one-time GitHub setup, cutting a release) are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Packaging files: Apache-2.0 (same as upstream). Ollaya itself and each model keep their own
licenses; the image includes upstream's `LICENSE` and third-party notices under
`/usr/share/doc/ollaya`.

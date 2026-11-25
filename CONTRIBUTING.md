# Contributing / maintaining

Audience: whoever publishes this repo's images and chart. Users: see [README.md](README.md).

## Workflows

All actions are pinned to commit SHAs.

| Workflow | Trigger | Does |
|---|---|---|
| [ci.yml](.github/workflows/ci.yml) | PR / push to `main` | hadolint, builds the CPU image (checks upstream sha256), starts it and waits for healthy, `helm lint` + renders every mode |
| [docker.yml](.github/workflows/docker.yml) | tag `vX.Y.Z` or manual | builds `cpu`/`cuda`/`cuda12` per-arch on native runners, merges into multi-arch tags on GHCR |
| [helm.yml](.github/workflows/helm.yml) | push to `main` touching `charts/**` | publishes the chart to GitHub Pages **and** `oci://ghcr.io/teochenglim/charts` |

## One-time setup

1. Push `main`. `helm.yml` creates the `gh-pages` branch automatically on its first run.
2. **Settings → Pages** → source: branch `gh-pages`. Then
   `https://teochenglim.github.io/ollaya/index.yaml` serves the Helm repo.
3. **Settings → Actions → General → Workflow permissions**: read and write.
4. After the first image/chart publish: **Packages → ollaya → Package settings → Change
   visibility → Public**, and link it to this repo. Do the same for `charts/ollaya`. Until then,
   anonymous `docker pull` / `helm install` fails.

## Release a new upstream version

1. Bump `appVersion` in [Chart.yaml](charts/ollaya/Chart.yaml) **and** the chart `version`
   (chart-releaser skips versions that already exist), and the default `OLLAYA_VERSION` in the
   [Dockerfile](Dockerfile).
2. Commit and push to `main` (publishes the chart).
3. Tag the image release; the tag's `X.Y.Z` must match an upstream release in
   [ollaya-dev/ollaya](https://github.com/ollaya-dev/ollaya/releases):
   ```sh
   git tag v0.19.0 && git push origin v0.19.0
   ```
   Or run **Actions → Publish image to GHCR → Run workflow** with a version, without a tag.

## Local checks before pushing

```sh
helm lint charts/ollaya
docker build -t ollaya:test .
docker run --rm -i hadolint/hadolint hadolint --failure-threshold warning - < Dockerfile
# on a local cluster with the docker runtime (colima/docker-desktop), no registry needed:
helm upgrade --install t charts/ollaya -n t --create-namespace \
  --set image.repository=ollaya --set image.tag=test --set image.pullPolicy=Never \
  --set service.type=NodePort --set service.nodePort=30808
```

## Notes

- The image repackages upstream's prebuilt tarballs; it never compiles Rust. If upstream renames
  its release assets (`ollaya-linux-<arch>[-cuda|-cuda12].tar.zst`, `sha256sum.txt`), update the
  `fetch` stage of the Dockerfile.
- Secrets (API key) are never baked into the image; the chart reads them from Kubernetes Secrets.

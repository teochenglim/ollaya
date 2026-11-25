# syntax=docker/dockerfile:1.7
#
# Lean Ollaya image: no Rust toolchain, no apt in the final layer chain beyond libgomp.
# Upstream's prebuilt, sha256-checked release tarballs are unpacked straight into /usr.
#
#   docker build -t ollaya .                                   # CPU
#   docker build --build-arg VARIANT=cuda   -t ollaya:cuda .   # NVIDIA, CUDA 13 (driver R580+)
#   docker build --build-arg VARIANT=cuda12 -t ollaya:cuda12 . # NVIDIA, CUDA 12 (driver R525+, amd64)
ARG DEBIAN_RELEASE=trixie

# ---- fetch: download + verify + unpack (discarded after COPY) ----------------------------------
FROM debian:${DEBIAN_RELEASE}-slim AS fetch
ARG OLLAYA_VERSION=0.18.0
ARG VARIANT=cpu
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Unpinned on purpose: Debian drops old package versions, which would break rebuilds.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl zstd \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eu; \
    base="https://github.com/ollaya-dev/ollaya/releases/download/v${OLLAYA_VERSION}"; \
    case "${VARIANT}" in \
      cpu)    extra="" ;; \
      cuda)   extra="ollaya-linux-${TARGETARCH}-cuda.tar.zst" ;; \
      cuda12) extra="ollaya-linux-${TARGETARCH}-cuda12.tar.zst" ;; \
      *) echo "unknown VARIANT=${VARIANT} (cpu|cuda|cuda12)" >&2; exit 1 ;; \
    esac; \
    files="ollaya-linux-${TARGETARCH}.tar.zst ${extra}"; \
    curl -fsSL --retry 3 -O "${base}/sha256sum.txt"; \
    for f in ${files}; do curl -fsSL --retry 3 -O "${base}/${f}"; done; \
    for f in ${files}; do grep -F "  ${f}" sha256sum.txt | sha256sum -c -; done; \
    mkdir /out; \
    for f in ${files}; do zstd -dc "${f}" | tar -xf - -C /out; done

# ---- runtime -----------------------------------------------------------------------------------
# Debian 13 slim: ONNX Runtime needs glibc >= 2.38; libgomp1 is needed by llama.cpp (GGUF).
FROM debian:${DEBIAN_RELEASE}-slim AS runtime
ARG OLLAYA_UID=1000
ARG OLLAYA_VERSION=0.18.0
ARG VARIANT=cpu
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 ca-certificates \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt /usr/share/doc /usr/share/man \
    && groupadd --gid "${OLLAYA_UID}" ollaya \
    && useradd --uid "${OLLAYA_UID}" --gid ollaya --home-dir /home/ollaya --create-home \
         --shell /usr/sbin/nologin ollaya \
    && mkdir -p /home/ollaya/.ollaya/models \
    && chown -R ollaya:ollaya /home/ollaya
COPY --from=fetch /out/ /usr/
COPY --chmod=0755 docker-healthcheck.sh /usr/local/bin/ollaya-healthcheck

# Secrets (OLLAYA_HF_TOKEN / HF_TOKEN, OLLAYA_API_KEY) are deliberately NOT set here:
# pass them at run time so they never land in an image layer.
ENV HOME=/home/ollaya \
    OLLAYA_HOST=0.0.0.0:11435 \
    OLLAYA_MODELS=/home/ollaya/.ollaya/models
EXPOSE 11435
VOLUME ["/home/ollaya/.ollaya"]
WORKDIR /home/ollaya
USER ${OLLAYA_UID}:${OLLAYA_UID}
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/ollaya-healthcheck"]
LABEL org.opencontainers.image.title="ollaya" \
      org.opencontainers.image.description="Ollaya decision-model server (repackaged upstream release)" \
      org.opencontainers.image.source="https://github.com/teochenglim/ollaya" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${OLLAYA_VERSION}" \
      dev.ollaya.variant="${VARIANT}"
ENTRYPOINT ["/usr/bin/ollaya"]
CMD ["serve"]

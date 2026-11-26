# syntax=docker/dockerfile:1.7

# ---------- Global build args (propagate to every stage) ----------
# LLAMA_VERSION: a tag (v1.0.0, b12602) or branch name. Source is always
#   fetched BY REF, then the resolved commit is verified against
#   LLAMA_COMMIT_SHA. The SHA check is what guarantees a moved or re-cut
#   tag cannot silently change what ships. Empty LLAMA_COMMIT_SHA = record
#   only, no enforcement.
# To upgrade: set LLAMA_VERSION, run the resolve script to get the new SHA,
# rebuild, note both in your changelog.
ARG LLAMA_VERSION=v1.0.0
ARG LLAMA_COMMIT_SHA=""

# Single place to bump the base image; both stages inherit it.
ARG BASE_IMAGE=ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b

# ---------- Build stage ----------
FROM ${BASE_IMAGE} AS build

ARG LLAMA_VERSION
ARG LLAMA_COMMIT_SHA

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates cmake build-essential ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Single fetch path: resolve whatever LLAMA_VERSION names (tag or branch),
# then hard-fail if it does not match the expected commit SHA. This keeps
# the tag->SHA verification in the loop even when the version arg is a raw
# SHA string (fetching arbitrary SHAs directly is not a guaranteed GitHub
# contract; going through a ref always is).
RUN git init -q . \
    && git remote add origin https://github.com/ggml-org/llama.cpp.git \
    && git fetch -q --depth 1 origin "${LLAMA_VERSION}" \
    && git checkout -q FETCH_HEAD \
    && RESOLVED="$(git rev-parse HEAD)" \
    && echo "resolved ${LLAMA_VERSION} -> ${RESOLVED}" \
    && if [ -z "${LLAMA_COMMIT_SHA}" ]; then \
        echo "NOTE: LLAMA_COMMIT_SHA empty — recording resolved SHA only, no verification." >&2; \
    elif [ "${LLAMA_COMMIT_SHA}" != "${RESOLVED}" ]; then \
        echo "FATAL: expected ${LLAMA_VERSION} to resolve to ${LLAMA_COMMIT_SHA}" >&2; \
        echo "       but it now resolves to ${RESOLVED}. Tag moved or wrong SHA?" >&2; \
        exit 1; \
    fi \
    && printf '%s\n' "${LLAMA_VERSION}" > /SOURCE_REF \
    && printf '%s\n' "${RESOLVED}"     > /REVISION

# CPU-only build, NO cURL: server cannot download models, only serve
# files mounted in at runtime. GGML_NATIVE=OFF keeps the binary portable
# across hosts; switch to ON if building and running on the same machine.
ARG BUILD_NATIVE="OFF"

# llama-server only — examples, tests and benchmarks are never run in this
# deployment and are omitted from the build entirely.
RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=${BUILD_NATIVE} \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_CURL=OFF \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_UI=OFF \
        -DLLAMA_USE_PREBUILT_UI=OFF \
    && cmake --build build --config Release \
             --target llama-server \
             --parallel "$(nproc --ignore=2)" \
    && install -m 0755 build/bin/llama-server /usr/local/bin/

# ---------- Runtime stage ----------
FROM ${BASE_IMAGE}

# curl is included ONLY so a compose-defined healthcheck can run inside the
# container. If your healthcheck probes from outside (or uses wget in a
# custom image), remove this line — the server itself never needs it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 curl \
    && rm -rf /var/lib/apt/lists/* \
    && userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 llama \
    && mkdir -p /models \
    && chown llama:llama /models

# Only the server binary ships to the runtime stage.
COPY --from=build /usr/local/bin/llama-server /usr/local/bin/

# Traceability: exact source ref + resolved commit, readable in any deployed
# image via `cat /source-ref /image-revision`. The SHA is additionally in the
# image labels, queryable via `docker inspect` without executing anything.
COPY --from=build /SOURCE_REF /source-ref
COPY --from=build /REVISION /image-revision

ARG LLAMA_VERSION
ARG LLAMA_COMMIT_SHA

LABEL org.opencontainers.image.title="llama.cpp server (hardened CPU build)" \
      org.opencontainers.image.source="https://github.com/ggml-org/llama.cpp" \
      org.opencontainers.image.ref.name="${LLAMA_VERSION}" \
      org.opencontainers.image.version="${LLAMA_VERSION}" \
      org.opencontainers.image.revision="${LLAMA_COMMIT_SHA}" \
      org.opencontainers.image.vendor="self-built" \
      org.opencontainers.image.description="API-only llama-server; no web UI, no cURL, non-root, SHA-verified build"

# No entrypoint wrapper: llama-server reads the API key straight from the
# Docker secret via --api-key-file (passed in CMD by your compose file).
# This avoids the key ever appearing in the process command line.
#
# If a client must authenticate without the secret file mounted, set the
# LLAMA_API_KEY environment variable instead — supported natively by
# llama-server. Do not pass --api-key on the command line.
#
# The compose file is the single source of truth for ALL server flags
# (host, port, model, context, threads, api-key-file). No CMD here on
# purpose: a bare `docker run` without a model path should fail fast
# rather than start half-configured.
USER llama
WORKDIR /models

EXPOSE 8080

# Healthcheck lives only in compose (deployment-specific). Generous
# start period there accounts for slow first-load of large GGUF files.

ENTRYPOINT ["/usr/local/bin/llama-server"]


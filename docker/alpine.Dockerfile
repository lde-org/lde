# lde on musl (Alpine): x86-64 / aarch64 builds.
#
#   docker build -f docker/alpine.Dockerfile \
#     --build-arg LDE_VERSION=v0.11.0 --platform linux/amd64 .
#
# ARG BASE pins the Alpine release; the CI matrix passes the same value.
ARG BASE=alpine:3.20

FROM ${BASE} AS downloader
# Build args are referenced as plain ${VAR}: a RUN is handed to /bin/sh as-is,
# so "$" belongs to the shell. A compose-style "$$" escape is left untouched and
# expands to the shell's PID, which the fetch script rejects as an architecture.
ARG LDE_VERSION
ARG TARGETARCH
COPY docker/fetch-lde.sh /usr/local/bin/fetch-lde.sh
RUN set -eu; \
    apk add --no-cache curl ca-certificates unzip; \
    fetch-lde.sh "${TARGETARCH}" -musl

FROM ${BASE}
# libgcc: the musl lde binary dlopens libgcc_s.so.1 at runtime (for unwinding).
# The rest is the toolchain for compiling package dependencies.
RUN apk add --no-cache \
        clang \
        cmake \
        ninja \
        make \
        git \
        ca-certificates \
        libgcc

COPY --from=downloader /out/lde /usr/local/bin/lde

ENTRYPOINT ["lde"]
CMD ["--help"]

# lde on glibc (Debian): x86-64 / aarch64 builds.
#
#   docker build -f docker/glibc.Dockerfile \
#     --build-arg LDE_VERSION=v0.10.0 --platform linux/amd64 .
#
# ARG BASE picks the Debian flavor: debian:bookworm (default) or
# debian:bookworm-slim for the "slim" image.
ARG BASE=debian:bookworm

FROM ${BASE} AS downloader
# Build args are referenced as plain ${VAR}: a RUN is handed to /bin/sh as-is,
# so "$" belongs to the shell. A compose-style "$$" escape is left untouched and
# expands to the shell's PID, giving
#   .../download/2913{LDE_VERSION}/lde-linux-2913{ARCH}.zip
# which 404s (curl exits 22), and the arch test never matches either.
ARG LDE_VERSION
ARG TARGETARCH
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates unzip; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /out; \
    case "${TARGETARCH}" in \
        amd64) ARCH=x86-64 ;; \
        arm64) ARCH=aarch64 ;; \
        *) echo "unsupported architecture: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/lde-org/lde/releases/download/${LDE_VERSION}/lde-linux-${ARCH}.zip"; \
    echo "fetching ${url}"; \
    curl -fSL --retry 5 --retry-all-errors -o /tmp/lde.zip "${url}"; \
    unzip -q /tmp/lde.zip -d /tmp/lde; \
    install -m755 "/tmp/lde/lde-linux-${ARCH}" /out/lde

FROM ${BASE}
# lde bundles its LuaJIT runtime and native libs (libcurl, libgit2, ...); the
# toolchain here is for compiling package dependencies (build.lua scripts,
# rockspecs, luarocks) which shell out to clang/gcc, cmake and ninja.
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        cmake \
        ninja-build \
        make \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=downloader /out/lde /usr/local/bin/lde

ENTRYPOINT ["lde"]
CMD ["--help"]

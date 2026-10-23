# lde on glibc (Debian): x86-64 / aarch64 builds.
#
#   docker build -f docker/glibc.Dockerfile \
#     --build-arg LDE_VERSION=v0.11.0 --platform linux/amd64 .
#
# ARG BASE picks the Debian flavor: debian:bookworm (default) or
# debian:bookworm-slim for the "slim" image.
ARG BASE=debian:bookworm

FROM ${BASE} AS downloader
# Build args are referenced as plain ${VAR}: a RUN is handed to /bin/sh as-is,
# so "$" belongs to the shell. A compose-style "$$" escape is left untouched and
# expands to the shell's PID, which the fetch script rejects as an architecture.
ARG LDE_VERSION
ARG TARGETARCH
COPY docker/fetch-lde.sh /usr/local/bin/fetch-lde.sh
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates unzip; \
    rm -rf /var/lib/apt/lists/*; \
    fetch-lde.sh "${TARGETARCH}"

FROM ${BASE}
# lde bundles its LuaJIT runtime and native libs (libcurl, libgit2, ...); the
# toolchain here is for compiling package dependencies (build.lua scripts,
# rockspecs, luarocks) which shell out to clang/gcc, cmake and ninja.
# libgcc-s1: the binary has a hard NEEDED libgcc_s.so.1 (unwinding), so declare
# it rather than relying on clang pulling it in transitively.
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        cmake \
        ninja-build \
        make \
        git \
        ca-certificates \
        libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=downloader /out/lde /usr/local/bin/lde

ENTRYPOINT ["lde"]
CMD ["--help"]

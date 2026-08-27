# lde on glibc (Debian): x86-64 / aarch64 builds.
#
#   docker build -f docker/glibc.Dockerfile \
#     --build-arg LDE_VERSION=v0.10.0 --platform linux/amd64 .
#
# ARG BASE picks the Debian flavor: debian:bookworm (default) or
# debian:bookworm-slim for the "slim" image.
ARG BASE=debian:bookworm

FROM ${BASE} AS downloader
ARG LDE_VERSION
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates unzip \
    && mkdir -p /out \
    && if [ "$$TARGETARCH" = "amd64" ]; then ARCH=x86-64; else ARCH=aarch64; fi \
    && curl -fsSLo /tmp/lde.zip \
        "https://github.com/lde-org/lde/releases/download/$${LDE_VERSION}/lde-linux-$${ARCH}.zip" \
    && unzip -q /tmp/lde.zip -d /tmp/lde \
    && install -m755 /tmp/lde/lde-linux-$${ARCH} /out/lde

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

# lde on musl (Alpine): x86-64 / aarch64 builds.
#
#   docker build -f docker/alpine.Dockerfile \
#     --build-arg LDE_VERSION=v0.10.0 --platform linux/amd64 .
FROM alpine:3.20 AS downloader
ARG LDE_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl ca-certificates unzip \
    && mkdir -p /out \
    && if [ "$$TARGETARCH" = "amd64" ]; then ARCH=x86-64; else ARCH=aarch64; fi \
    && curl -fsSLo /tmp/lde.zip \
        "https://github.com/lde-org/lde/releases/download/$${LDE_VERSION}/lde-linux-$${ARCH}-musl.zip" \
    && unzip -q /tmp/lde.zip -d /tmp/lde \
    && install -m755 /tmp/lde/lde-linux-$${ARCH}-musl /out/lde

FROM alpine:3.20
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

# lde on musl (Alpine): x86-64 / aarch64 builds.
#
#   docker build -f docker/alpine.Dockerfile \
#     --build-arg LDE_VERSION=v0.10.0 --platform linux/amd64 .
FROM alpine:3.20 AS downloader
# Build args are referenced as plain ${VAR}: a RUN is handed to /bin/sh as-is,
# so "$" belongs to the shell. A compose-style "$$" escape is left untouched and
# expands to the shell's PID, giving
#   .../download/2913{LDE_VERSION}/lde-linux-2913{ARCH}-musl.zip
# which 404s (curl exits 22), and the arch test never matches either.
ARG LDE_VERSION
ARG TARGETARCH
RUN set -eu; \
    apk add --no-cache curl ca-certificates unzip; \
    mkdir -p /out; \
    case "${TARGETARCH}" in \
        amd64) ARCH=x86-64 ;; \
        arm64) ARCH=aarch64 ;; \
        *) echo "unsupported architecture: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/lde-org/lde/releases/download/${LDE_VERSION}/lde-linux-${ARCH}-musl.zip"; \
    echo "fetching ${url}"; \
    curl -fSL --retry 5 --retry-all-errors -o /tmp/lde.zip "${url}" \
        || { echo "no musl asset at ${url}: musl builds exist for the nightly and" \
                "for releases after the musl matrix entries were added" >&2; exit 1; }; \
    unzip -q /tmp/lde.zip -d /tmp/lde; \
    install -m755 "/tmp/lde/lde-linux-${ARCH}-musl" /out/lde

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

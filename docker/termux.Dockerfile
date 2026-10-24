# Android (Termux) build environment for the Android matrix entry.
#
#   docker build -f docker/termux.Dockerfile --platform linux/arm64 .
FROM termux/termux-docker:aarch64

# The base image's apt refuses to run as root; its entrypoint normally drops to
# the Android system user (1000:1000), and the image's own Dockerfile builds its
# package layer the same way. Restore root afterwards so the entrypoint still
# drops privileges for the running container.
USER 1000:1000
RUN apt update && apt install -y clang cmake ninja openssl git
USER 0

#!/bin/sh
# Fetch the lde release asset for one architecture into /out/lde.
#
#   fetch-lde.sh TARGETARCH [-musl]
#
# LDE_VERSION is a build arg, which a RUN receives as an environment variable.
# The caller passes "-musl" for the musl asset and nothing for the glibc asset.
set -eu

arch=${1:?usage: fetch-lde.sh TARGETARCH [-musl]}
libc=${2:-}

case "${arch}" in
	amd64) target=x86-64 ;;
	arm64) target=aarch64 ;;
	*) echo "unsupported architecture: '${arch}'" >&2; exit 1 ;;
esac

asset="lde-linux-${target}${libc}"
url="https://github.com/lde-org/lde/releases/download/${LDE_VERSION}/${asset}.zip"
echo "fetching ${url}"

# Keep curl's exit status (22 on an HTTP error) as the failure code.
status=0
curl -fSL --retry 5 --retry-all-errors -o /tmp/lde.zip "${url}" || status=$?
if [ "${status}" -ne 0 ]; then
	if [ "${libc}" = "-musl" ]; then
		echo "no musl asset at ${url}: musl builds exist for the nightly and" \
			"for releases after the musl matrix entries were added" >&2
	fi
	exit "${status}"
fi

unzip -q /tmp/lde.zip -d /tmp/lde
mkdir -p /out
install -m755 "/tmp/lde/${asset}" /out/lde

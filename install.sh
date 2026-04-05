#!/bin/sh
set -e

DIR="$HOME/.lde"
REPO="lde-org/lde"
NIGHTLY=0
VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --nightly) NIGHTLY=1 ;;
        --version) VERSION="$2"; shift ;;
    esac
    shift
done

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS-$ARCH" in
    Linux-x86_64)          BIN="lde-linux-x86-64" ;;
    Linux-aarch64)         BIN="lde-linux-aarch64" ;;
    Darwin-x86_64)         BIN="lde-macos-x86-64" ;;
    Darwin-arm64)          BIN="lde-macos-aarch64" ;;
    *) echo "Unsupported platform: $OS $ARCH"; exit 1 ;;
esac

if [ "$NIGHTLY" = "1" ]; then
    TAG="nightly"
elif [ -n "$VERSION" ]; then
    TAG="v$VERSION"
else
    TAG=$(curl -sfL "https://github.com/$REPO/releases/latest" -o /dev/null -w '%{url_effective}' | sed 's|.*/||')
fi

mkdir -p "$DIR"
curl -fL "https://github.com/$REPO/releases/download/$TAG/$BIN" -o "$DIR/lde"
chmod +x "$DIR/lde" && "$DIR/lde" --setup

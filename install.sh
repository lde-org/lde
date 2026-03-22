#!/bin/sh
set -e

DIR="$HOME/.lpm"
REPO="codebycruz/lpm"
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
    Linux-x86_64)          BIN="lpm-linux-x86-64" ;;
    Linux-aarch64)         BIN="lpm-linux-aarch64" ;;
    Darwin-x86_64)         echo "Intel macOS is currently unsupported."; exit 1 ;;
    Darwin-arm64)          BIN="lpm-macos-aarch64" ;;
    *) echo "Unsupported platform: $OS $ARCH"; exit 1 ;;
esac

if [ "$NIGHTLY" = "1" ]; then
    TAG="nightly"
elif [ -n "$VERSION" ]; then
    TAG="v$VERSION"
else
    TAG=$(curl -sf "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
fi

mkdir -p "$DIR"
curl -fL "https://github.com/$REPO/releases/download/$TAG/$BIN" -o "$DIR/lpm"
chmod +x "$DIR/lpm" && "$DIR/lpm" --setup

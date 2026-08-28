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

ARCH="$(uname -m)"
[ "$(uname -o)" = "Android" ] && OS="Android" || OS="$(uname -s)"

MUSL=0
if [ "$OS" = "Linux" ] && ls /lib/ld-musl-* >/dev/null 2>&1; then
    MUSL=1
fi

TRIPLE="$OS-$ARCH"

case "$TRIPLE" in
    Linux-x86_64)                BIN="lde-linux-x86-64" ;;
    Linux-aarch64)               BIN="lde-linux-aarch64" ;;
    Android-aarch64)             BIN="lde-android-aarch64" ;;
    Darwin-x86_64)               BIN="lde-macos-x86-64" ;;
    Darwin-arm64)                BIN="lde-macos-aarch64" ;;
    *) echo "Unsupported platform: $TRIPLE"; exit 1 ;;
esac

if [ "$MUSL" = "1" ]; then
    BIN="${BIN}-musl"
fi

if [ "$NIGHTLY" = "1" ]; then
    TAG="nightly"
elif [ -n "$VERSION" ]; then
    TAG="v$VERSION"
else
    TAG=$(curl -sfL "https://github.com/$REPO/releases/latest" -o /dev/null -w '%{url_effective}' | sed 's|.*/||')
fi

mkdir -p "$DIR"
ZIP="$DIR/lde.zip"
curl -fL "https://github.com/$REPO/releases/download/$TAG/$BIN.zip" -o "$ZIP"

if command -v unzip >/dev/null 2>&1; then
    unzip -o -q "$ZIP" -d "$DIR"
elif command -v busybox >/dev/null 2>&1; then
    busybox unzip -o -q "$ZIP" -d "$DIR"
elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$DIR"
else
    echo "Error: no unzip available (install unzip, busybox, or python3 and re-run)" >&2
    rm -f "$ZIP"
    exit 1
fi

mv "$DIR/$BIN" "$DIR/lde"
rm -f "$ZIP"
chmod +x "$DIR/lde" && "$DIR/lde" --setup

#!/bin/sh
set -e

DIR="$HOME/.lpm"
REPO="codebycruz/lpm"

case "$(uname -m)" in
    x86_64)        BIN="lpm-linux-x86-64" ;;
    aarch64|arm64) BIN="lpm-linux-aarch64" ;;
    *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
esac

TAG=$(curl -sf "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

mkdir -p "$DIR"
curl -fL "https://github.com/$REPO/releases/download/$TAG/$BIN" -o "$DIR/lpm"
chmod +x "$DIR/lpm" && "$DIR/lpm" --setup

#!/bin/sh

set -e

REPO="codebycruz/lpm"
LPM_DIR="$HOME/.lpm"

echo "Installing lpm..."

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ARTIFACT="lpm-linux-x86-64"
        ;;
    aarch64|arm64)
        ARTIFACT="lpm-linux-aarch64"
        ;;
    *)
        echo "Error: Unsupported architecture: $ARCH"
        echo "Supported architectures: x86_64, aarch64"
        exit 1
        ;;
esac

# Get latest release tag
TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$TAG" ]; then
    echo "Error: Could not fetch latest release"
    exit 1
fi

echo "Latest version: $TAG"

# Download and install binary
mkdir -p "$LPM_DIR"
curl -L -o "$LPM_DIR/lpm" "https://github.com/$REPO/releases/download/$TAG/$ARTIFACT"
chmod +x "$LPM_DIR/lpm"

# Finish setup (PATH, lpx)
"$LPM_DIR/lpm" --setup

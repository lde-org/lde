#!/usr/bin/env bash

set -e

if ! type nix-prefetch-url &>/dev/null; then
	echo "This tool requires nix-prefetch-url"
	exit 1
fi

repo="codebycruz/lpm"
releaseTag="v0.7.1"

attrs() {
	indent="        "
	target="lpm-$1-$2"
	url="https://github.com/$repo/releases/download/$releaseTag/$target"
	echo "${indent}url = \"$url\";"
	hash="$(nix-prefetch-url "$url" 2>/dev/null)"
	echo "${indent}hash = \"$hash\";"
}

cat <<EOF
platform_attrs = {
    "aarch64-darwin" = {
$(attrs macos aarch64)
    };
    "aarch64-linux" = {
$(attrs linux aarch64)
    };
    "x86_64-linux" = {
$(attrs linux x86-64)
    };
};
EOF

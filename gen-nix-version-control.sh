#!/usr/bin/env bash

set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$script_dir" || exit

if ! type nix-prefetch-url &>/dev/null; then
	echo "This tool requires nix-prefetch-url"
	exit 1
fi

repo="codebycruz/lpm"
releaseTag="$(git describe --tags --abbrev=0 2>/dev/null)"
flake_file="flake.nix"

attrs() {
	indent="          "
	target="lpm-$1-$2"
	url="https://github.com/$repo/releases/download/$releaseTag/$target"
	echo "${indent}url = \"$url\";"
	sha256="$(nix-prefetch-url "$url" 2>/dev/null)"
	echo "${indent}sha256 = \"$sha256\";"
}

new_attrs_block=$(
	cat <<EOF
      # GENERATED VERSION CONTROL - BEGIN
      releaseTag = "$releaseTag";
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
      # GENERATED VERSION CONTROL - END
EOF
)

# AI generated command to update flake.nix automatically
temp_file=$(mktemp)
awk -v new_block="$new_attrs_block" '
  /# GENERATED VERSION CONTROL - BEGIN/ {
    print new_block
    # Skip until the end marker
    while (getline > 0 && $0 !~ /# GENERATED VERSION CONTROL - END/) {}
    next
  }
  { print }
' "$flake_file" >"$temp_file"
mv "$temp_file" "$flake_file"

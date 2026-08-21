# Recipes for working on the lde monorepo.
# Requires `just` and the `lde` binary on PATH (see AGENTS.md).

# Run the full test suite across all packages
test:
    lde test

# Type-check all packages with lua-language-server; prints a colored summary
[no-exit-message]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="$(pwd)"
    LLS="${LUA_LANGUAGE_SERVER:-lua-language-server}"
    META_DIR="$ROOT/.lls/meta"
    LOG_DIR="$ROOT/.lls/log"
    mkdir -p "$META_DIR" "$LOG_DIR"
    total_files=$(find "$ROOT/packages" -name '*.lua' -not -path '*/target/*' | wc -l)
    failed_files=0
    failed_pkgs=0
    passed_pkgs=0
    for pkg in "$ROOT"/packages/*/; do
        [ -d "$pkg/src" ] || continue
        out=$(LLS_META_PATH="$META_DIR" LLS_LOG_PATH="$LOG_DIR" "$LLS" \
            --check="$pkg" \
            --configpath="$ROOT/.luarc.json" \
            --checklevel=Warning 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tr '\r' '\n' || true)
        if printf '%s\n' "$out" | grep -qE 'Diagnosis complete[d]?, [0-9]+ problems found'; then
            count=$(printf '%s\n' "$out" | grep -oP 'Diagnosis complete[d]?, \K[0-9]+' | tail -1)
            ff=$(printf '%s\n' "$out" | grep -oP 'Found [0-9]+ problems in \K[0-9]+' | tail -1)
            failed_files=$((failed_files + ${ff:-0}))
            failed_pkgs=$((failed_pkgs + 1))
            printf '\033[1;31m✗ %s — %s problem(s)\033[0m\n' "$(basename "$pkg")" "$count"
            printf '%s\n' "$out" | grep -E '\[(Error|Warning)\]' | while IFS= read -r line; do
                if printf '%s' "$line" | grep -q '\[Error\]'; then
                    printf '\033[31m  %s\033[0m\n' "$line"
                else
                    printf '\033[33m  %s\033[0m\n' "$line"
                fi
            done
        else
            passed_pkgs=$((passed_pkgs + 1))
        fi
    done
    if [ "$failed_pkgs" -ne 0 ]; then
        passed_files=$((total_files - failed_files))
        printf '\033[1;31m✗ %d file(s) failed\033[0m, \033[1;32m%d passed\033[0m\n' "$failed_files" "$passed_files"
        exit 1
    fi
    printf '\033[1;32m✓ %d files checked, no errors\033[0m\n' "$total_files"

#!/usr/bin/env bash
# oh-no-my-contributor — uninstall guardrails from the current repo.
#
# Removes ONLY what the installer added:
#   - restores core.hooksPath from .githooks/ohnmc.previous-hooks-path
#     (written by --force installs) or unsets it if it is .githooks
#   - deletes .githooks/prepare-commit-msg, allowed-identities and
#     ohnc.* files; removes .githooks/ only if it ends up empty
#   - removes the marked block from AGENTS.md / CLAUDE.md
#
# *.ohnmc.bak files are kept: they hold pre-install copies for manual
# restore. Nothing else in the repo is touched.
#
# Usage: uninstall.sh
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: not inside a git repository" >&2
    exit 1
}
cd "$ROOT"

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# --- git hook ---------------------------------------------------------------
CURRENT_HOOKSPATH="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ -d .githooks ]; then
    if [ -f .githooks/ohnmc.previous-hooks-path ]; then
        PREV="$(cat .githooks/ohnmc.previous-hooks-path)"
        git config core.hooksPath "$PREV"
        say "core.hooksPath restored to: $PREV"
    elif [ "$CURRENT_HOOKSPATH" = ".githooks" ]; then
        git config --unset core.hooksPath
        say "core.hooksPath unset (was .githooks)"
    else
        warn "core.hooksPath is '$CURRENT_HOOKSPATH', not ours - left untouched."
    fi

    rm -f .githooks/prepare-commit-msg .githooks/reference-transaction \
          .githooks/allowed-identities \
          .githooks/ohnmc.previous-hooks-path .githooks/*.ohnmc.bak \
          .githooks/prepare-commit-msg.ohnmc.bak .githooks/reference-transaction.ohnmc.bak
    # Remove .githooks only if nothing else lives there.
    if [ -z "$(find .githooks -mindepth 1 -print -quit 2>/dev/null)" ]; then
        rmdir .githooks && say "removed empty .githooks/"
    else
        warn ".githooks/ still contains other files - left in place."
    fi
else
    say "no .githooks/ directory found - hook part already absent."
fi

# --- instruction blocks -------------------------------------------------------
for f in AGENTS.md CLAUDE.md; do
    [ -f "$f" ] || continue
    if grep -q "oh-no-my-contributor:start" "$f"; then
        if ! grep -q "oh-no-my-contributor:end" "$f"; then
            warn "$f has a start marker but no end marker - left untouched."
            continue
        fi
        tmp="$f.ohnmc-uninstall.tmp"
        awk '
            /<!-- oh-no-my-contributor:start -->/ { skip=1; next }
            /<!-- oh-no-my-contributor:end -->/ { skip=0; next }
            !skip { print }
        ' "$f" > "$tmp" && mv "$tmp" "$f"
        say "removed oh-no-my-contributor block from $f"
    fi
done

say ""
say "oh-no-my-contributor uninstalled."
say "Note: *.ohnmc.bak files were kept - delete them manually if unneeded."
say "Note: history already rewritten stays rewritten; this only removes the guardrails."

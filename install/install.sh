#!/usr/bin/env bash
# oh-no-my-contributor — install AI-attribution guardrails into the current repo.
#
# V2 safety rules:
#   * NEVER overrides an existing hook setup (core.hooksPath, Husky,
#     Lefthook, real files in .git/hooks) unless --force is passed.
#   * --force backs up the previous hooksPath and existing .githooks
#     content before touching anything.
#   * Idempotent: re-running refreshes our files, never duplicates.
#   * Instruction blocks carry markers; files are backed up once as
#     <name>.ohnmc.bak before the first modification.
#
# Usage: install.sh [--force]
set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: not inside a git repository" >&2
    exit 1
}
cd "$ROOT"
GIT_DIR="$(git rev-parse --git-dir)"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# --- detect existing hook infrastructure ------------------------------------
EXISTING_HOOKSPATH="$(git config --get core.hooksPath 2>/dev/null || true)"
HOOK_CONFLICTS=""

# hooksPath already pointing at .githooks is our own previous install,
# not a conflict. Anything else would be bypassed by our hooksPath.
if [ -n "$EXISTING_HOOKSPATH" ] && [ "$EXISTING_HOOKSPATH" != ".githooks" ]; then
    HOOK_CONFLICTS="$HOOK_CONFLICTS core.hooksPath=$EXISTING_HOOKSPATH"
fi
[ -d .husky ] && HOOK_CONFLICTS="$HOOK_CONFLICTS .husky/"
grep -qs '"husky"' package.json 2>/dev/null && HOOK_CONFLICTS="$HOOK_CONFLICTS husky(package.json)"
{ [ -f lefthook.yml ] || [ -f lefthook.yaml ]; } && HOOK_CONFLICTS="$HOOK_CONFLICTS lefthook.yml"

# Real (non-sample) hooks in the default .git/hooks dir would be bypassed
# once core.hooksPath points elsewhere.
for h in pre-commit commit-msg prepare-commit-msg post-commit reference-transaction; do
    if [ -f "$GIT_DIR/hooks/$h" ]; then
        HOOK_CONFLICTS="$HOOK_CONFLICTS .git/hooks/$h"
    fi
done

# --- decide whether the git hook can be installed safely --------------------
INSTALL_HOOK=1
if [ -n "$HOOK_CONFLICTS" ] && [ "$FORCE" -eq 0 ]; then
    INSTALL_HOOK=0
    warn "existing hook setup detected:$HOOK_CONFLICTS"
    warn "setting core.hooksPath=.githooks would bypass it. Skipping the git hook."
    warn "Re-run with --force to install anyway (previous config is backed up)."
fi

if [ "$INSTALL_HOOK" -eq 1 ]; then
    # Backup the previous hooksPath so uninstall can restore it.
    # Skip when it already is .githooks (our own install, nothing to restore).
    if [ -n "$EXISTING_HOOKSPATH" ] && [ "$EXISTING_HOOKSPATH" != ".githooks" ] && [ "$FORCE" -eq 1 ]; then
        mkdir -p .githooks
        printf '%s\n' "$EXISTING_HOOKSPATH" > .githooks/ohnmc.previous-hooks-path
        # Preserve any hook files already living in our target dir.
        for f in .githooks/*; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in
                prepare-commit-msg|reference-transaction|allowed-identities|ohnmc.*) ;;
                *) [ -f "$f.ohnmc.bak" ] || cp "$f" "$f.ohnmc.bak" ;;
            esac
        done
    fi

    mkdir -p .githooks

    # Never silently overwrite different pre-existing hook files.
    for hook in prepare-commit-msg reference-transaction; do
        if [ -f ".githooks/$hook" ] && [ ! -f ".githooks/$hook.ohnmc.bak" ]; then
            if ! cmp -s <(sed 's/\r$//' "$SKILL_DIR/assets/$hook.sh") \
                        <(sed 's/\r$//' ".githooks/$hook"); then
                cp ".githooks/$hook" ".githooks/$hook.ohnmc.bak"
                warn "existing .githooks/$hook differed - backed up to .ohnmc.bak"
            fi
        fi
    done

    # sed 's/\r$//' normalizes to LF: a CRLF shebang breaks the hook on
    # Linux/macOS when the skill folder was zipped on Windows.
    for hook in prepare-commit-msg reference-transaction; do
        sed 's/\r$//' "$SKILL_DIR/assets/$hook.sh" > ".githooks/$hook"
        chmod +x ".githooks/$hook"
    done

    # Allowlist = the repo owner's current git identities (author + committer).
    ident() { git var "$1" 2>/dev/null | sed -E 's/[[:space:]]+[0-9]+[[:space:]]+[+-][0-9]{4}$//'; }
    {
        ident GIT_AUTHOR_IDENT
        ident GIT_COMMITTER_IDENT
    } | sed '/^$/d' | sort -u > .githooks/allowed-identities

    if [ ! -s .githooks/allowed-identities ]; then
        warn "git user.name/user.email are not configured — the identity gate"
        warn "cannot work. Configure them, then re-run this installer."
        warn "(Instruction block still installed below.)"
        INSTALL_HOOK=0
    else
        git config core.hooksPath .githooks
        say "hooks installed: .githooks/prepare-commit-msg + reference-transaction"
        say "allowlist:       .githooks/allowed-identities ($(wc -l < .githooks/allowed-identities | tr -d ' ') identities)"
    fi
fi

# --- instruction block in AGENTS.md / CLAUDE.md ------------------------------
BLOCK="$SKILL_DIR/assets/ai-attribution-block.md"
for f in AGENTS.md CLAUDE.md; do
    if [ -f "$f" ] && grep -q "oh-no-my-contributor:start" "$f"; then
        if ! grep -q "oh-no-my-contributor:end" "$f"; then
            warn "$f has a start marker but no end marker — leaving it untouched."
            continue
        fi
        [ -f "$f.ohnmc.bak" ] || cp "$f" "$f.ohnmc.bak"
        tmp="$f.ohnmc.tmp"
        awk -v blockfile="$BLOCK" '
            /<!-- oh-no-my-contributor:start -->/ { while ((getline l < blockfile) > 0) print l; skip=1; next }
            /<!-- oh-no-my-contributor:end -->/ { skip=0; next }
            !skip { print }
        ' "$f" > "$tmp" && mv "$tmp" "$f"
    elif [ -f "$f" ]; then
        [ -f "$f.ohnmc.bak" ] || cp "$f" "$f.ohnmc.bak"
        { printf '\n'; cat "$BLOCK"; } >> "$f"
    else
        cat "$BLOCK" > "$f"
    fi
done

say ""
say "oh-no-my-contributor installed:"
[ "$INSTALL_HOOK" -eq 1 ] && say "  - hook:    .githooks/prepare-commit-msg + reference-transaction (identity gate + trailer strip)" \
                   || say "  - hook:    SKIPPED (existing hook setup detected — see warnings)"
say "  - rules:   AGENTS.md + CLAUDE.md (oh-no-my-contributor block)"
say ""
say "Notes:"
say "  - core.hooksPath is per-clone: on a fresh clone run 'git config core.hooksPath .githooks' once."
say "  - .githooks/ and the instruction files should be committed so the team gets them."
say "  - If core.fileMode is off (Windows), run once after committing:"
say "      git update-index --chmod=+x .githooks/prepare-commit-msg"
say "  - Existing history is NOT touched. Clean it with scripts/clean_ai_authorship.py"
[ "$INSTALL_HOOK" -eq 0 ] && say "    (manual hook integration needed — see warnings above)."
say ""
say "Uninstall:"
say "  git config --unset core.hooksPath"
say "  remove .githooks/ (only if this installer created it)"
say "  delete <!-- oh-no-my-contributor:start/end --> blocks from AGENTS.md / CLAUDE.md"
say "  .ohnmc.bak files hold pre-install copies of edited files."

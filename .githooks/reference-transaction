#!/bin/sh
# oh-no-my-contributor — deep identity gate (reference-transaction).
#
# Runs on every reference update, in the "prepared" state only, where a
# non-zero exit aborts the whole transaction. It catches the paths that
# prepare-commit-msg cannot see:
#
#   - git commit-tree + git update-ref
#   - git am / git rebase / plumbing-created commits
#   - git tag -a (annotated tag objects carry a tagger, no commit hook)
#
# What it enforces (same rules as prepare-commit-msg):
#   - committer must be in .githooks/allowed-identities
#   - committer and tagger matching AI patterns are rejected
#   - author matching an AI pattern is rejected
#
# Deliberate safety valves:
#   - skipped during fetch/clone/receive (GIT_QUARANTINE_PATH) so
#     pulling foreign objects can never brick a clone
#   - only objects NOT reachable from any existing ref are checked, so
#     branching, resetting or tagging old history never breaks
#   - commit messages are NOT checked here: blocking on trailers would
#     make rebasing pre-cleanup history impossible. Trailer stripping
#     stays in prepare-commit-msg.
#
# Keep the regexes below in sync with prepare-commit-msg.sh.

[ "${1:-}" = "prepared" ] || exit 0
[ -n "${GIT_QUARANTINE_PATH:-}" ] && exit 0

hook_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
allow_file="$hook_dir/allowed-identities"

fail() { echo "oh-no-my-contributor: $1" >&2; exit 1; }

[ -f "$allow_file" ] || fail "allowlist missing ($allow_file). Re-run install/install.sh in this repo."
for tool in git grep sed sort; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found in PATH."
done

STRONG_RE='devin-ai-integration|devin\.ai|cursoragent|copilot|@anthropic\.com|claude\.ai|claude-code|openai|chatgpt|gemini-code-assist|google-labs-jules|aider|windsurf|codeium|cline|amazon[- ]?q|\[bot\]@|(^|[^a-z0-9])bot@'
WEAK_RE='(^|[^a-z0-9_])(claude|cursor|devin|gemini|chatgpt|codex)([^a-z0-9_]|$)'
MACHINE_RE='noreply|\[bot\]|users\.noreply\.github\.com|@anthropic\.com|@claude\.ai|claude-code|@openai\.com|@cursor\.|cursoragent|devin-ai|@codeium\.|@windsurf\.|@aider|@cline|jules|gemini-code-assist|copilot'

# $1 = "Name <email>" -> 0 if it looks like an AI/bot identity
is_ai() {
    printf '%s' "$1" | grep -qiE "$STRONG_RE" && return 0
    printf '%s' "$1" | grep -qE "$WEAK_RE" || return 1
    em="$(printf '%s' "$1" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
    [ -n "$em" ] && printf '%s' "$em" | grep -qiE "$MACHINE_RE"
}

ZERO=0000000000000000000000000000000000000000

while read -r old new ref; do
    [ -n "$new" ] || continue
    [ "$new" = "$ZERO" ] && continue
    case "$ref" in refs/heads/*|refs/tags/*) ;; *) continue;; esac

    otype="$(git cat-file -t "$new" </dev/null 2>/dev/null)" || continue

    if [ "$otype" = "tag" ]; then
        # Annotated tag object: always new, check its tagger.
        tagger="$(git cat-file tag "$new" </dev/null 2>/dev/null \
            | sed -n 's/^tagger //p' | head -1 \
            | sed -E 's/[[:space:]]+[0-9]+[[:space:]]+[+-][0-9]{4}$//')"
        [ -n "$tagger" ] || continue
        is_ai "$tagger" && fail "tagger identity looks like an AI/bot: $tagger"
        grep -qxF "$tagger" "$allow_file" || \
            fail "tagger '$tagger' is not in $allow_file. Use the repository owner's identity, or re-run install to update the allowlist."
        continue
    fi

    [ "$otype" = "commit" ] || continue

    # Committer: must be allowlisted and never AI-pattern. Identities are
    # deduplicated first so a big rebase only checks a handful of lines.
    # while-read on a here-doc keeps fail() in the current shell.
    ids="$(git log --format='%cn <%ce>' "$new" --not --all </dev/null 2>/dev/null | sort -u)"
    while IFS= read -r ident; do
        [ -n "$ident" ] || continue
        is_ai "$ident" && fail "committer identity looks like an AI/bot: $ident"
        grep -qxF "$ident" "$allow_file" || \
            fail "committer '$ident' is not in $allow_file. Use the repository owner's identity, or re-run install to update the allowlist."
    done <<EOF
$ids
EOF

    # Author: AI-pattern rejected; other humans may legitimately author.
    ids="$(git log --format='%an <%ae>' "$new" --not --all </dev/null 2>/dev/null | sort -u)"
    while IFS= read -r ident; do
        [ -n "$ident" ] || continue
        is_ai "$ident" && fail "author identity looks like an AI/bot: $ident"
    done <<EOF
$ids
EOF
done

exit 0

#!/bin/sh
# oh-no-my-contributor — deep identity gate (reference-transaction).
# "prepared" state only: non-zero exit aborts the ref transaction.
# Catches what prepare-commit-msg cannot: commit-tree+update-ref, git am,
# git tag -a and other plumbing paths.
#
# Same identity rules as prepare-commit-msg (committer allowlist +
# AI-pattern rejection on committer/tagger/author), plus the same
# trailer rules applied as rejection: plumbing commits are immutable,
# so AI attribution in their message aborts the transaction instead
# of being stripped. Only commits unreachable from any ref are scanned,
# so pre-cleanup history never trips this; run the cleanup first.
#
# Keep the regexes below in sync with prepare-commit-msg.sh.

[ "${1:-}" = "prepared" ] || exit 0
[ -n "${GIT_QUARANTINE_PATH:-}" ] && exit 0

hook_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
allow_file="$hook_dir/allowed-identities"

fail() { echo "oh-no-my-contributor: $1" >&2; exit 1; }

[ -f "$allow_file" ] || fail "allowlist missing ($allow_file). Re-run install/install.sh in this repo."
for tool in git grep sed sort awk head; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found in PATH."
done

STRONG_RE='devin-ai-integration|devin\.ai|cursoragent|copilot|@anthropic\.com|claude\.ai|claude-code|openai|chatgpt|gemini-code-assist|google-labs-jules|aider|windsurf|codeium|cline|amazon[- ]?q|\[bot\]@|(^|[^a-z0-9])bot@'
WEAK_RE='(^|[^a-z0-9_])(claude|cursor|devin|gemini|chatgpt|codex)([^a-z0-9_]|$)'
MACHINE_RE='noreply|\[bot\]|users\.noreply\.github\.com|@anthropic\.com|@claude\.ai|claude-code|@openai\.com|@cursor\.|cursoragent|devin-ai|@codeium\.|@windsurf\.|@aider|@cline|jules|gemini-code-assist|copilot'
TOOL_RE='devin|claude|anthropic|cursor|copilot|chatgpt|openai|codex|gemini|jules|aider|windsurf|codeium|cline|amazon[- ]?q|gpt'

# $1 = "Name <email>" -> 0 if it looks like an AI/bot identity
is_ai() {
    printf '%s' "$1" | grep -qiE "$STRONG_RE" && return 0
    printf '%s' "$1" | grep -qiE "$WEAK_RE" || return 1
    em="$(printf '%s' "$1" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
    [ -n "$em" ] && printf '%s' "$em" | grep -qiE "$MACHINE_RE"
}

# awk -v parses values like string literals: \[ would collapse to a
# bracket expression. Double every backslash so the regex survives.
awkesc() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }

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

    # Message: same trailer rules as prepare-commit-msg, applied as
    # rejection (commit objects are immutable once hashed). Human
    # co-author/signed-off trailers pass because is_ai() keeps the
    # two-level matching.
    bad="$(git log --format=%B "$new" --not --all </dev/null 2>/dev/null \
        | awk -v strong="$(awkesc "$STRONG_RE")" -v weak="$(awkesc "$WEAK_RE")" \
              -v mach="$(awkesc "$MACHINE_RE")" -v tools="$TOOL_RE" '
        function ai_ident(s,   em) {
            if (tolower(s) ~ strong) return 1
            if (tolower(s) ~ weak) {
                em = s; sub(/.*</, "", em); sub(/>.*/, "", em)
                if (em ~ mach) return 1
            }
            return 0
        }
        {
            l = tolower($0)
            if (l ~ /^[ \t]*(co-authored-by|signed-off-by):/) {
                id = $0; sub(/^[^:]*:[ \t]*/, "", id)
                if (ai_ident(id)) print
            } else if (l ~ /^[ \t]*generated[ \t]+(with|by)[ \t]/ || l ~ /^[^a-z0-9]*generated[ \t]+(with|by)[ \t]/) {
                rest = $0; sub(/^[ \t]*/, "", rest); sub(/^[^a-zA-Z]+/, "", rest)
                if (tolower(rest) ~ tools) print
            }
        }' | head -1)"
    [ -z "$bad" ] || fail "commit message contains AI attribution: $bad"
done

exit 0

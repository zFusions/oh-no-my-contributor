#!/bin/sh
# oh-no-my-contributor — commit gate (prepare-commit-msg).
# Not skipped by `git commit --no-verify` (unlike pre-commit/commit-msg).
#
# 1. Identity gate: committer must be in allowed-identities; AI-pattern
#    author/committer rejected. Fails closed if config is missing.
# 2. Message gate: AI attribution trailers stripped before recording.
#
# Two-level matching (same as clean_ai_authorship.py): STRONG patterns
# always count as AI; WEAK tokens (claude, gemini...) only with a
# machine-looking email, so humans with those names are untouched.

msg="${1:-}"
hook_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
allow_file="$hook_dir/allowed-identities"

fail() { echo "oh-no-my-contributor: $1" >&2; exit 1; }

[ -f "$allow_file" ] || fail "allowlist missing ($allow_file). Re-run install/install.sh in this repo."
command -v git >/dev/null 2>&1 || fail "git not found in PATH."
command -v grep >/dev/null 2>&1 || fail "grep not found in PATH."
command -v awk >/dev/null 2>&1 || fail "awk not found in PATH."
command -v sed >/dev/null 2>&1 || fail "sed not found in PATH."

# "Name <email> 1700000000 +0100" -> "Name <email>"
ident() { git var "$1" 2>/dev/null | sed -E 's/[[:space:]]+[0-9]+[[:space:]]+[+-][0-9]{4}$//'; }

STRONG_RE='devin-ai-integration|devin\.ai|cursoragent|copilot|@anthropic\.com|claude\.ai|claude-code|openai|chatgpt|gemini-code-assist|google-labs-jules|aider|windsurf|codeium|cline|amazon[- ]?q|\[bot\]@|(^|[^a-z0-9])bot@'
WEAK_RE='(^|[^a-z0-9_])(claude|cursor|devin|gemini|chatgpt|codex)([^a-z0-9_]|$)'
MACHINE_RE='noreply|\[bot\]|users\.noreply\.github\.com|@anthropic\.com|@claude\.ai|claude-code|@openai\.com|@cursor\.|cursoragent|devin-ai|@codeium\.|@windsurf\.|@aider|@cline|jules|gemini-code-assist|copilot'
TOOL_RE='devin|claude|anthropic|cursor|copilot|chatgpt|openai|codex|gemini|jules|aider|windsurf|codeium|cline|amazon[- ]?q|gpt'

# $1 = "Name <email>" -> 0 if it looks like an AI/bot identity
is_ai() {
    printf '%s' "$1" | grep -qiE "$STRONG_RE" && return 0
    printf '%s' "$1" | grep -qE "$WEAK_RE" || return 1
    em="$(printf '%s' "$1" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
    [ -n "$em" ] && printf '%s' "$em" | grep -qiE "$MACHINE_RE"
}

committer="$(ident GIT_COMMITTER_IDENT)"
author="$(ident GIT_AUTHOR_IDENT)"
[ -n "$committer" ] || fail "cannot resolve committer identity."
[ -n "$author" ] || fail "cannot resolve author identity."

# 1a. AI-pattern identities are always rejected, allowlist or not.
is_ai "$committer" && fail "committer identity looks like an AI/bot: $committer"
is_ai "$author" && fail "author identity looks like an AI/bot: $author"

# 1b. The committer must be one of the identities recorded at install time
#     (normally the repo owner's git config).
grep -qxF "$committer" "$allow_file" || \
    fail "committer '$committer' is not in $allow_file. Commit as the repository owner, or re-run install to update the allowlist."

# Author is intentionally NOT restricted to the allowlist: cherry-picks
# and rebases legitimately carry other human authors. AI-pattern authors
# are already rejected above.

# 2. Strip AI attribution trailers from the message.
if [ -n "$msg" ] && [ -f "$msg" ]; then
    tmp="$msg.ohnmc.tmp"
    # awk -v parses values like string literals: \[ would collapse to a
    # bracket expression. Double every backslash so the regex survives.
    awkesc() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }
    awk -v strong="$(awkesc "$STRONG_RE")" -v weak="$(awkesc "$WEAK_RE")" \
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
                if (ai_ident(id)) next
            } else if (l ~ /^[ \t]*generated[ \t]+(with|by)[ \t]/ || l ~ /^[^a-z0-9]*generated[ \t]+(with|by)[ \t]/) {
                rest = $0; sub(/^[ \t]*/, "", rest); sub(/^[^a-zA-Z]+/, "", rest)
                if (tolower(rest) ~ tools) next
            }
            print
        }' "$msg" > "$tmp" 2>/dev/null || true
    if [ -f "$tmp" ]; then
        if [ ! -s "$tmp" ] && [ -s "$msg" ]; then
            rm -f "$tmp"
            fail "commit message would be empty after stripping AI attribution. Write a real message."
        fi
        mv "$tmp" "$msg"
    fi
fi

exit 0

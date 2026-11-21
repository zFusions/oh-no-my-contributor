#!/bin/sh
msg="${1:-}"
hook_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
allow_file="$hook_dir/allowed-identities"

fail() { echo "oh-no-my-contributor: $1" >&2; exit 1; }

[ -f "$allow_file" ] || fail "allowlist missing ($allow_file). Re-run install/install.sh in this repo."
command -v git >/dev/null 2>&1 || fail "git not found in PATH."
command -v grep >/dev/null 2>&1 || fail "grep not found in PATH."
command -v awk >/dev/null 2>&1 || fail "awk not found in PATH."
command -v sed >/dev/null 2>&1 || fail "sed not found in PATH."

ident() { git var "$1" 2>/dev/null | sed -E 's/[[:space:]]+[0-9]+[[:space:]]+[+-][0-9]{4}$//'; }

STRONG_RE='devin-ai-integration|devin\.ai|cursoragent|copilot|@anthropic\.com|claude\.ai|claude-code|openai|chatgpt|gemini-code-assist|google-labs-jules|aider|windsurf|codeium|cline|amazon[- ]?q|\[bot\]@|(^|[^a-z0-9])bot@'
WEAK_RE='(^|[^a-z0-9_])(claude|cursor|devin|gemini|chatgpt|codex)([^a-z0-9_]|$)'
MACHINE_RE='noreply|\[bot\]|users\.noreply\.github\.com|@anthropic\.com|@claude\.ai|claude-code|@openai\.com|@cursor\.|cursoragent|devin-ai|@codeium\.|@windsurf\.|@aider|@cline|jules|gemini-code-assist|copilot'
TOOL_RE='devin|claude|anthropic|cursor|copilot|chatgpt|openai|codex|gemini|jules|aider|windsurf|codeium|cline|amazon[- ]?q|gpt'

is_ai() {
    printf '%s' "$1" | grep -qiE "$STRONG_RE" && return 0
    printf '%s' "$1" | grep -qiE "$WEAK_RE" || return 1
    em="$(printf '%s' "$1" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
    [ -n "$em" ] && printf '%s' "$em" | grep -qiE "$MACHINE_RE"
}

committer="$(ident GIT_COMMITTER_IDENT)"
author="$(ident GIT_AUTHOR_IDENT)"
[ -n "$committer" ] || fail "cannot resolve committer identity."
[ -n "$author" ] || fail "cannot resolve author identity."

is_ai "$committer" && fail "committer identity looks like an AI/bot: $committer"
is_ai "$author" && fail "author identity looks like an AI/bot: $author"

grep -qxF "$committer" "$allow_file" || \
    fail "committer '$committer' is not in $allow_file. Commit as the repository owner, or re-run install to update the allowlist."

if [ -n "$msg" ] && [ -f "$msg" ]; then
    tmp="$(mktemp "$msg.ohnmc.XXXXXX" 2>/dev/null)" || tmp="$msg.ohnmc.$$"
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

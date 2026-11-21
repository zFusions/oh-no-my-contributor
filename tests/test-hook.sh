#!/usr/bin/env bash
set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3] got [$2])"; fi; }
check_blocked(){ if [ "$2" -ne 0 ] 2>/dev/null; then ok "$1"; else bad "$1 (expected non-zero, got [$2])"; fi; }

mkdir -p "$T/repo/.githooks"
cp "$SKILL_DIR/assets/prepare-commit-msg.sh" "$T/repo/.githooks/prepare-commit-msg"
cp "$SKILL_DIR/assets/reference-transaction.sh" "$T/repo/.githooks/reference-transaction"
chmod +x "$T/repo/.githooks/prepare-commit-msg" "$T/repo/.githooks/reference-transaction"
cd "$T/repo"
git init -q
git config user.name "Repo Owner"
git config user.email "owner@example.com"
git config core.hooksPath .githooks
printf 'Repo Owner <owner@example.com>\n' > .githooks/allowed-identities

run_hook() { bash .githooks/prepare-commit-msg "$1" >/dev/null 2>&1; }

echo "== message gate =="

printf 'fix: bug\n\nCo-Authored-By: Devin <158243242+devin-ai-integration[bot]@users.noreply.github.com>\nGenerated with [Claude](https://claude.ai)\n' > m1
run_hook m1; rc=$?
check "AI trailers stripped, exit 0" "$rc" "0"
check "trailer gone" "$(grep -c 'Co-Authored' m1)" "0"
check "generated-with gone" "$(grep -ci 'generated' m1)" "0"
check "subject kept" "$(head -1 m1)" "fix: bug"

printf 'feat: x\n\nCo-authored-by: Alice <alice@example.com>\n' > m2
run_hook m2
check "human co-author preserved" "$(grep -c 'alice@example.com' m2)" "1"

printf 'feat: y\n' > m3
run_hook m3
check "clean message untouched" "$(cat m3)" "feat: y"

printf 'feat: z\n\nCo-authored-by: Claude <claude.human@gmail.com>\n' > m3b
run_hook m3b
check "human named Claude co-author preserved" "$(grep -c 'claude.human@gmail.com' m3b)" "1"

printf 'feat: w\n\nSigned-off-by: devin-ai-integration[bot] <158243242+devin-ai-integration[bot]@users.noreply.github.com>\nSigned-off-by: Alice <alice@example.com>\n' > m3c
run_hook m3c
check "AI signed-off-by stripped" "$(grep -c 'devin-ai' m3c)" "0"
check "human signed-off-by preserved" "$(grep -c 'alice@example.com' m3c)" "1"

echo "== identity gate =="

printf 'fix: z\n' > m4

env GIT_COMMITTER_NAME="devin-ai-integration[bot]" GIT_COMMITTER_EMAIL="b@x.com" bash .githooks/prepare-commit-msg m4 >/dev/null 2>&1
check "AI committer blocked" "$?" "1"

env GIT_COMMITTER_NAME="Random Person" GIT_COMMITTER_EMAIL="r@x.com" bash .githooks/prepare-commit-msg m4 >/dev/null 2>&1
check "non-allowlisted committer blocked" "$?" "1"

env GIT_AUTHOR_NAME="Claude" GIT_AUTHOR_EMAIL="noreply@anthropic.com" bash .githooks/prepare-commit-msg m4 >/dev/null 2>&1
check "AI-pattern author blocked" "$?" "1"

env GIT_AUTHOR_NAME="Claude" GIT_AUTHOR_EMAIL="claude.human@gmail.com" bash .githooks/prepare-commit-msg m4 >/dev/null 2>&1
check "human named Claude author passes" "$?" "0"

env GIT_AUTHOR_NAME="Gemini" GIT_AUTHOR_EMAIL="gemini@gmail.com" bash .githooks/prepare-commit-msg m4 >/dev/null 2>&1
check "human named Gemini author passes" "$?" "0"

env GIT_COMMITTER_NAME="Repo Owner" GIT_COMMITTER_EMAIL="owner@example.com" bash .githooks/prepare-commit-msg m4 >/dev/null 2>&1
check "owner committer passes" "$?" "0"

echo "== fail closed =="
mv .githooks/allowed-identities .githooks/allowed-identities.bak
run_hook m4
check "missing allowlist blocks commit" "$?" "1"
mv .githooks/allowed-identities.bak .githooks/allowed-identities

echo "== empty-after-strip =="
printf 'Co-Authored-By: Devin <158243242+devin-ai-integration[bot]@users.noreply.github.com>\n' > m5
run_hook m5
check "trailer-only message refused, not emptied" "$?" "1"

echo "== end-to-end: --no-verify still gated =="
git config user.name "Repo Owner"; git config user.email "owner@example.com"
echo x > f.txt; git add f.txt
git commit -q --no-verify -m "test" -m "Co-Authored-By: Devin <158243242+devin-ai-integration[bot]@users.noreply.github.com>"
check "no-verify commit message clean" "$(git log -1 --format=%B | grep -c 'Co-Authored')" "0"

echo "== reference-transaction: plumbing bypass attempts =="
TREE="$(git rev-parse 'HEAD^{tree}')"
PARENT="$(git rev-parse HEAD)"

AI_C="$(GIT_COMMITTER_NAME='devin-ai-integration[bot]' GIT_COMMITTER_EMAIL='b@x.com' \
       GIT_AUTHOR_NAME='Repo Owner' GIT_AUTHOR_EMAIL='owner@example.com' \
       git commit-tree "$TREE" -p "$PARENT" -m evil </dev/null)"
git update-ref refs/heads/evil-ai "$AI_C" >/dev/null 2>&1
check_blocked "commit-tree AI committer blocked" "$?"
check "evil branch not created" "$(git rev-parse --verify -q refs/heads/evil-ai; echo $?)" "1"

AI_A="$(GIT_COMMITTER_NAME='Repo Owner' GIT_COMMITTER_EMAIL='owner@example.com' \
       GIT_AUTHOR_NAME='Claude' GIT_AUTHOR_EMAIL='noreply@anthropic.com' \
       git commit-tree "$TREE" -p "$PARENT" -m evil2 </dev/null)"
git update-ref refs/heads/evil-author "$AI_A" >/dev/null 2>&1
check_blocked "commit-tree AI author blocked" "$?"

OK_C="$(GIT_COMMITTER_NAME='Repo Owner' GIT_COMMITTER_EMAIL='owner@example.com' \
       GIT_AUTHOR_NAME='Repo Owner' GIT_AUTHOR_EMAIL='owner@example.com' \
       git commit-tree "$TREE" -p "$PARENT" -m legit </dev/null)"
git update-ref refs/heads/legit "$OK_C" >/dev/null 2>&1
check "commit-tree owner committer allowed" "$?" "0"

TRAILER_C="$(GIT_COMMITTER_NAME='Repo Owner' GIT_COMMITTER_EMAIL='owner@example.com' \
       GIT_AUTHOR_NAME='Repo Owner' GIT_AUTHOR_EMAIL='owner@example.com' \
       git commit-tree "$TREE" -p "$PARENT" -m legit \
       -m "Co-Authored-By: Devin <158243242+devin-ai-integration[bot]@users.noreply.github.com>" </dev/null)"
git update-ref refs/heads/evil-trailer "$TRAILER_C" >/dev/null 2>&1
check_blocked "commit-tree AI trailer blocked" "$?"

HUMAN_C="$(GIT_COMMITTER_NAME='Repo Owner' GIT_COMMITTER_EMAIL='owner@example.com' \
       GIT_AUTHOR_NAME='Repo Owner' GIT_AUTHOR_EMAIL='owner@example.com' \
       git commit-tree "$TREE" -p "$PARENT" -m legit \
       -m "Co-Authored-By: Claude <claude.human@gmail.com>" </dev/null)"
git update-ref refs/heads/human-trailer "$HUMAN_C" >/dev/null 2>&1
check "commit-tree human trailer allowed" "$?" "0"

GIT_COMMITTER_NAME='Claude' GIT_COMMITTER_EMAIL='noreply@anthropic.com' \
  git tag -a v-evil -m taggy >/dev/null 2>&1
check_blocked "annotated tag AI tagger blocked" "$?"

git tag -a v-ok -m taggy >/dev/null 2>&1
check "annotated tag owner tagger allowed" "$?" "0"

git branch old-history "$PARENT" >/dev/null 2>&1
check "branch onto existing commit allowed" "$?" "0"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

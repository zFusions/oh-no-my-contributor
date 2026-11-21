# Oh no, my contributor

*Your repo. Your name on it. No AI in the contributors graph.*

[![tests](https://github.com/zFusions/oh-no-my-contributor/actions/workflows/test.yml/badge.svg)](https://github.com/zFusions/oh-no-my-contributor/actions/workflows/test.yml)

You asked an AI to build your project. It built your project. Then it
helpfully signed its own name on every commit like a toddler drawing
on your furniture with a permanent marker.

```
feat: add login page

Co-Authored-By: devin-ai-integration[bot]
Generated with Claude
Signed-off-by: cursoragent
```

Now GitHub's contributors graph shows **four AIs and one human**, and
your repo looks like a group project where the group was ChatGPT.

This skill fixes that. Past *and* future.

## What it does

```
scan → report → clean → protect
```

### 1. Scan

Read-only report of every AI author, committer, tagger and message
trailer in the repo. Works without a configured git identity.

### 2. Clean

Rewrites history on a *copy* with `git-filter-repo`:

- AI identities become yours
- AI trailers disappear from commit messages
- **every** commit's file tree is verified identical through the
  commit-map — not just branch tips
- a `backup.git` stays on disk, untouched
- push is manual, with `--force-with-lease`

Your code does not change. Only the fingerprints do.

### 3. Protect

Two hooks, because one hook is a suggestion and two hooks are a policy.

**`prepare-commit-msg`** — runs on `git commit` and `git merge`,
*including* `git commit --no-verify` (yes, that flag does not skip it):

- committer must match the owner identity recorded at install time
- AI-pattern author identities are rejected
- AI trailers (`Co-authored-by`, `Signed-off-by`, `Generated with/by`)
  are stripped — humans named Claude or Gemini are safe, the matcher is
  two-level on purpose
- a message that would become empty is refused with an explanation
- missing config or tools → the commit fails closed, not open

**`reference-transaction`** — the bouncer for the back door. The first
hook cannot see plumbing, so this one watches every ref update:

- `git commit-tree` + `update-ref`? Checked.
- `git am`, `git rebase`, `git tag -a`? Checked.
- AI trailers in a plumbing commit's message? Rejected — objects are
  immutable once hashed, so the transaction aborts instead of
  rewriting.
- It only inspects objects no existing ref can reach, so your old
  history never gets in the way, and it sleeps through fetch/clone so
  pulling can never brick anything.

Plus an instruction block injected into `AGENTS.md` / `CLAUDE.md` so
every AI agent that reads the repo knows the rules before it even
reaches for `git commit`.

## Install

The whole `oh-no-my-contributor/` folder **is** the skill. Drop it into
whichever skills directory your agent reads:

| Agent | Path |
|---|---|
| Devin | `.devin/skills/oh-no-my-contributor/` |
| Claude Code | `.claude/skills/oh-no-my-contributor/` |
| Cursor / agents.md-compatible | your skills directory, or repo root |
| Anything else | keep the folder next to the project and point the agent at `SKILL.md` |

Then just say: *"clean my AI attribution"*, *"remove AI contributors
from this repo"*, or *"oh no my contributor"*.

Or run the installer directly:

```bash
bash install/install.sh        # Linux / macOS / Git Bash
powershell -File install/install.ps1   # Windows PowerShell
```

The installer **never breaks existing hooks**: if it finds
`core.hooksPath`, Husky, Lefthook or real hooks in `.git/hooks`, it
skips the git hook and warns you instead of overriding. `--force`
overrides with a backup of the previous config.

To leave: `install/uninstall.sh` / `uninstall.ps1` removes exactly what
was added and restores a previous `core.hooksPath` when `--force`
recorded one.

## Requirements

- `git` 2.22+
- Python 3.8+ with `git-filter-repo` (`pip install git-filter-repo`)
  — only needed for the history cleanup, not for the guardrails

## The fine print (read it, it's short)

This tool rewrites git *metadata*, never file contents. Before anything
is pushed, the script compares the tree of **every single commit**
(old → new via commit-map). Worst case, you keep `backup.git` and
re-clone. There is no scenario where your code changes.

**Honest limits:**

- `core.hooksPath` is per-clone local config — on a fresh clone, run
  `git config core.hooksPath .githooks` once (or re-run the installer).
- The hooks cover every porcelain path (`commit`, `merge`, `am`,
  `rebase`, `cherry-pick`, `tag`) and the common plumbing paths
  (`commit-tree` + `update-ref`). What remains: `git fast-import`,
  commits made outside git (the GitHub web UI never sees local hooks),
  and deliberate sabotage — editing `.git/config`, deleting the hooks,
  rewriting objects by hand. No local tool can stop that.
- The identity gate stops bots committing *under their own name*. It
  cannot prove humanity: `GIT_COMMITTER_*` env vars can be set to the
  owner's identity. Seatbelt, not border wall.
- AI-pattern matching is heuristic. It can miss an unknown tool and,
  rarely, flag a human whose name looks machine-generated. Read the
  dry-run report before confirming.
- `reference-transaction` rejects AI trailers in new commit messages
  but cannot rewrite them: a plumbing commit (`commit-tree`) with the
  owner's identity and AI trailers is refused, not cleaned. Use
  `git commit`/`merge` for messages you want stripped automatically.
- Committed from Windows? The exec bit may be missing
  (`core.fileMode` is off):
  `git update-index --chmod=+x .githooks/prepare-commit-msg .githooks/reference-transaction`
- History cleanup cannot retract data already cached by third parties
  (search indexes, forks); it cleans the canonical repo.
- Rewriting history drops GPG/SSH commit signatures.

## Layout

```
oh-no-my-contributor/
├── SKILL.md                     # agent workflow: scan → clean → protect
├── scripts/
│   └── clean_ai_authorship.py   # verified history rewriter
├── assets/
│   ├── prepare-commit-msg.sh    # commit gate (identity + trailer strip)
│   ├── reference-transaction.sh # ref gate: catches plumbing/tag bypasses
│   └── ai-attribution-block.md  # rules injected into AGENTS.md/CLAUDE.md
├── install/
│   ├── install.sh / install.ps1 # idempotent, conflict-aware installer
│   └── uninstall.sh / .ps1      # removes only what was added
├── tests/
│   └── test-hook.sh             # 25-case hook test matrix
└── .github/workflows/test.yml   # CI: hooks on 3 OS, installer + uninstaller,
                                 #     Python dry-run on a fixture repo
```

## License

MIT — do whatever you want with it, just keep your name on your commits.

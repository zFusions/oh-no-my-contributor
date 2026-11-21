#!/usr/bin/env python3
"""Rewrite git history so AI tool identities become yours and AI
attribution trailers are removed from commit messages.

Never touches file contents (every commit tree is verified identical),
never touches other humans' commits, never pushes automatically.
Keeps an untouched backup.git; rewriting happens on rewritten.git.

Requires: Python 3.8+, Git 2.22+, `pip install git-filter-repo`.

Usage:
  python clean_ai_authorship.py --dry-run          # report only
  python clean_ai_authorship.py                    # rewrite (current repo)
  python clean_ai_authorship.py --source <url|path>
  python clean_ai_authorship.py --pattern <regex>  # extra AI pattern
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

# Patterns (case-insensitive regex) tested against "Name <email>".
# Two levels:
#   - STRONG: unambiguous AI-tool signatures, always removed.
#   - WEAK:   tokens that are also common names/words (Claude, Cursor,
#     Devin...). Removed only when the email looks machine-generated,
#     so a human contributor named Claude or Devin is never erased.
STRONG_PATTERNS = [
    r"devin-ai-integration",
    r"cursoragent",
    r"copilot",
    r"@anthropic\.com|claude\.ai|claude-code",
    r"openai|chatgpt|\bcodex\b",
    r"gemini-code-assist|google-labs-jules",
    r"\baider\b",
    r"windsurf|codeium|\bcline\b|amazon[- ]?q",
    r"\[bot\]@|@.*\.bot\b|\bbot@",
]
WEAK_PATTERNS = [
    r"\bclaude\b",
    r"\bcursor\b",
    r"\bdevin\b",
    r"\bgemini\b",
    r"\bchatgpt\b",
    r"\bcodex\b",
]
MACHINE_EMAIL_RE = re.compile(
    r"noreply|\[bot\]|bot@|users\.noreply\.github\.com|"
    r"@anthropic\.com|@claude\.ai|claude-code|@openai\.com|@cursor\.|"
    r"cursoragent|devin-ai|@codeium\.|@windsurf\.|@aider|@cline|jules|"
    r"gemini-code-assist|copilot",
    re.IGNORECASE,
)

COAUTHOR_RE = re.compile(r"^\s*co-authored-by:\s*(.+)$", re.IGNORECASE)
SIGNEDOFF_RE = re.compile(r"^\s*signed-off-by:\s*(.+)$", re.IGNORECASE)
GENERATED_RE = re.compile(r"^\s*(?:🤖\s*)?generated\s+(?:with|by)\b(.*)$", re.IGNORECASE)
AI_WORDS_RE = re.compile(
    r"claude|anthropic|cursor|chatgpt|gpt|gemini|copilot|devin|openai|codex|"
    r"aider|windsurf|codeium|cline|jules|amazon q",
    re.IGNORECASE,
)


def git(args, cwd=None, check=True):
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and result.returncode != 0:
        sys.exit(f"ERROR:git {' '.join(args)}\n{result.stderr.strip()}")
    return result.stdout.strip()


EMAIL_RE = re.compile(r"<([^>]+)>")


def identity_is_ai(identity, strong, weak):
    """Two levels: a strong pattern alone is enough; a weak pattern also
    requires a machine-looking email."""
    if any(p.search(identity) for p in strong):
        return True
    if not any(p.search(identity) for p in weak):
        return False
    m = EMAIL_RE.search(identity)
    return bool(m and MACHINE_EMAIL_RE.search(m.group(1)))


def is_ai(name, email, strong, weak):
    return identity_is_ai(f"{name} <{email}>", strong, weak)


def strip_ai_lines(text, strong, weak):
    """Remove AI Co-authored-by / Signed-off-by trailers and
    "Generated with/by <AI>" lines."""
    kept, removed = [], 0
    for line in text.split("\n"):
        co = COAUTHOR_RE.match(line)
        so = SIGNEDOFF_RE.match(line)
        gen = GENERATED_RE.match(line)
        drop = False
        if (co or so) and identity_is_ai((co or so).group(1), strong, weak):
            drop = True
        elif gen and (AI_WORDS_RE.search(gen.group(1)) or any(p.search(gen.group(1)) for p in strong)):
            drop = True
        if drop:
            removed += 1
        else:
            kept.append(line)
    if not removed:
        return text, 0
    return "\n".join(kept).rstrip() + "\n", removed


def repo_name(source):
    base = source.rstrip("/\\").replace("\\", "/").split("/")[-1]
    if base.endswith(".git"):
        base = base[:-4]
    return base or "repo"


def resolve_source(arg):
    """Default source: the LOCAL repository (includes unpushed commits).
    --source remains available to scan a remote or another path."""
    if arg:
        return arg
    top = git(["rev-parse", "--show-toplevel"], check=False)
    if not top:
        sys.exit("ERROR: not inside a git repository. Use --source <url or path>.")
    return top


def scan_tags(repo, strong, weak):
    """Count AI taggers on annotated tags."""
    # for-each-ref does not interpret %xNN: use a literal "|" separator.
    out = git(
        ["for-each-ref", "--format=%(objecttype)|%(refname)|%(taggername)|%(taggeremail)",
         "refs/tags"],
        cwd=repo,
        check=False,
    )
    stats = Counter()
    identities = Counter()
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) < 4 or parts[0] != "tag":
            continue  # lightweight tags have no tagger
        _, ref, tname, temail = parts[0], parts[1], parts[2], "|".join(parts[3:])
        if is_ai(tname, temail, strong, weak):
            stats["ai tagger tags"] += 1
            identities[f"{tname} <{temail}> ({ref})"] += 1
    return stats, identities


def scan(repo, strong, weak):
    """Count what would be changed, without changing anything."""
    out = git(
        ["log", "--all", "--format=%an%x1f%ae%x1f%cn%x1f%ce%x1f%B%x1e"],
        cwd=repo,
        check=False,
    )
    stats = Counter()
    identities = Counter()
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record.strip():
            continue
        parts = record.split("\x1f", 4)
        if len(parts) < 5:
            continue
        an, ae, cn, ce, body = parts
        stats["commits"] += 1
        if is_ai(an, ae, strong, weak):
            stats["ai authors"] += 1
            identities[f"{an} <{ae}>"] += 1
        if is_ai(cn, ce, strong, weak):
            stats["ai committers"] += 1
            identities[f"{cn} <{ce}>"] += 1
        if strip_ai_lines(body, strong, weak)[1]:
            stats["messages to clean"] += 1
    tag_stats, tag_ids = scan_tags(repo, strong, weak)
    stats.update(tag_stats)
    identities.update(tag_ids)
    return stats, identities


def print_report(title, stats, identities):
    print(f"\n=== {title} ===")
    print(f"Commits scanned           : {stats['commits']}")
    print(f"Commits with AI author    : {stats['ai authors']}")
    print(f"Commits with AI committer : {stats['ai committers']}")
    print(f"Messages to clean         : {stats['messages to clean']}")
    print(f"Tags with AI tagger       : {stats['ai tagger tags']}")
    if identities:
        print("AI identities found:")
        for ident, count in identities.most_common():
            print(f"  - {ident} ({count})")


def rewrite(repo, name, email, strong, weak):
    try:
        import git_filter_repo as fr
    except ImportError:
        sys.exit("ERROR: git-filter-repo missing. Install it with:  pip install git-filter-repo")

    name_b, email_b = name.encode("utf-8"), email.encode("utf-8")

    def dec(raw):
        return (raw or b"").decode("utf-8", errors="replace")

    def fix_message(raw):
        if raw is None:
            return raw
        text = raw.decode("utf-8", errors="surrogateescape")
        new_text, removed = strip_ai_lines(text, strong, weak)
        if removed:
            return new_text.encode("utf-8", errors="surrogateescape")
        return raw

    def commit_cb(commit, metadata):
        if is_ai(dec(commit.author_name), dec(commit.author_email), strong, weak):
            commit.author_name, commit.author_email = name_b, email_b
        if is_ai(dec(commit.committer_name), dec(commit.committer_email), strong, weak):
            commit.committer_name, commit.committer_email = name_b, email_b
        commit.message = fix_message(commit.message)

    def tag_cb(tag, metadata):
        if tag.tagger_name is not None and is_ai(dec(tag.tagger_name), dec(tag.tagger_email), strong, weak):
            tag.tagger_name, tag.tagger_email = name_b, email_b
        tag.message = fix_message(tag.message)

    previous_cwd = os.getcwd()
    os.chdir(repo)
    try:
        args = fr.FilteringOptions.parse_args(["--force"], error_on_empty=False)
        fr.RepoFilter(args, commit_callback=commit_cb, tag_callback=tag_cb).run()
    finally:
        os.chdir(previous_cwd)


def list_refs(repo):
    out = git(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags"], cwd=repo, check=False)
    return set(out.splitlines())


def commit_map_pairs(rewritten):
    """Read the commit-map produced by git-filter-repo: (old, new) SHA pairs."""
    map_path = Path(rewritten) / "filter-repo" / "commit-map"
    if not map_path.exists():
        return []
    pairs = []
    for line in map_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        cols = line.split()
        if len(cols) >= 2 and re.fullmatch(r"[0-9a-f]{40,64}", cols[0]) and re.fullmatch(r"[0-9a-f]{40,64}", cols[1]):
            pairs.append((cols[0], cols[1]))
    return pairs


def verify(backup, rewritten):
    """Prove the code did not move:
    - same refs, same commit count per ref;
    - for EVERY commit (via commit-map), the rewritten tree is identical
      to the original tree — not just branch tips."""
    problems = []
    refs_a, refs_b = list_refs(backup), list_refs(rewritten)
    if refs_a != refs_b:
        problems.append(f"Different refs: {sorted(refs_a ^ refs_b)}")
    for ref in sorted(refs_a & refs_b):
        count_a = git(["rev-list", "--count", ref], cwd=backup, check=False)
        count_b = git(["rev-list", "--count", ref], cwd=rewritten, check=False)
        if count_a != count_b:
            problems.append(f"Different commit count on {ref} ({count_a} -> {count_b})")

    pairs = commit_map_pairs(rewritten)
    if not pairs:
        problems.append("commit-map missing or empty: per-commit verification impossible")
        return problems, len(refs_a & refs_b)

    for old_sha, new_sha in pairs:
        tree_a = git(["rev-parse", f"{old_sha}^{{tree}}"], cwd=backup, check=False)
        tree_b = git(["rev-parse", f"{new_sha}^{{tree}}"], cwd=rewritten, check=False)
        if not tree_a or not tree_b or tree_a != tree_b:
            problems.append(f"TREE DIFFERS on commit {old_sha[:12]}")
            if len(problems) > 20:
                problems.append("...")
                break
    return problems, len(refs_a & refs_b)


def main():
    parser = argparse.ArgumentParser(description="Replace AI identities with yours in git history.")
    parser.add_argument("--source", help="Repo URL or path (default: current local repo, unpushed commits included)")
    parser.add_argument("--name", help="Your name (default: git config user.name)")
    parser.add_argument("--email", help="Your email (default: git config user.email)")
    parser.add_argument("--pattern", action="append", default=[], help="Extra regex pattern (repeatable)")
    parser.add_argument("--out-dir", help="Output directory (default: ../<repo>-history-rewrite)")
    parser.add_argument("--dry-run", action="store_true", help="Report only, no rewrite")
    parser.add_argument("--yes", action="store_true", help="Skip the confirmation prompt")
    opts = parser.parse_args()

    if shutil.which("git") is None:
        sys.exit("ERROR: git not found.")

    # Identity is only required for rewriting, not for scanning.
    name = opts.name or git(["config", "user.name"], check=False)
    email = opts.email or git(["config", "user.email"], check=False)
    if not opts.dry_run and (not name or not email):
        sys.exit("ERROR: provide --name and --email (or set git config user.name/user.email) for rewriting. --dry-run does not need them.")

    try:
        strong = [re.compile(p, re.IGNORECASE) for p in STRONG_PATTERNS + opts.pattern]
        weak = [re.compile(p, re.IGNORECASE) for p in WEAK_PATTERNS]
    except re.error as exc:
        sys.exit(f"ERROR: invalid regex pattern: {exc}")

    source = resolve_source(opts.source)
    name_dir = repo_name(source)

    # Bare clone: only branches and tags (no GitHub refs/pull).
    if opts.dry_run:
        tmp = Path(tempfile.mkdtemp(prefix="ai-scan-"))
        try:
            print(f"Temporary clone of {source} ...")
            git(["clone", "--bare", "--no-local", source, str(tmp / "scan.git")])
            stats, identities = scan(tmp / "scan.git", strong, weak)
            print_report("REPORT (dry-run, nothing was modified)", stats, identities)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return

    out_dir = Path(opts.out_dir) if opts.out_dir else Path.cwd().parent / f"{name_dir}-history-rewrite"
    backup, rewritten = out_dir / "backup.git", out_dir / "rewritten.git"
    if out_dir.exists():
        sys.exit(f"ERROR: {out_dir} already exists. Delete it or choose --out-dir.")
    out_dir.mkdir(parents=True)

    print(f"Source           : {source}")
    print(f"New identity     : {name} <{email}>")
    print(f"Output directory : {out_dir}")
    print("Cloning the backup (untouched) ...")
    git(["clone", "--bare", "--no-local", source, str(backup)])

    before_stats, before_ids = scan(backup, strong, weak)
    print_report("BEFORE", before_stats, before_ids)
    dirty = (before_stats["ai authors"] or before_stats["ai committers"]
             or before_stats["messages to clean"] or before_stats["ai tagger tags"])
    if not dirty:
        print("\nNothing to clean. No changes made.")
        return

    print("\nNote: signed commits (GPG/SSH) will lose their signature after rewriting.")

    if not opts.yes:
        answer = input("\nRewrite a COPY of the history with these rules? [y/N] ").strip().lower()
        if answer not in ("o", "y", "yes"):
            print("Cancelled. Nothing was modified.")
            return

    shutil.copytree(backup, rewritten)
    print("Rewriting in progress (on the copy) ...")
    rewrite(rewritten, name, email, strong, weak)

    after_stats, after_ids = scan(rewritten, strong, weak)
    print_report("AFTER", after_stats, after_ids)

    problems, checked = verify(backup, rewritten)
    print(f"\n=== INTEGRITY CHECK ({checked} branches/tags compared) ===")
    if problems:
        print("FAILED, push NOTHING:")
        for problem in problems:
            print(f"  - {problem}")
        sys.exit(1)
    print("OK: every file tree is strictly identical, no code was modified.")

    # Push target: if the source is a local path, reuse its "origin"
    # remote (e.g. GitHub) instead of pushing back into the worktree clone.
    is_remote = "://" in source or source.startswith("git@")
    push_url = source
    if not is_remote:
        upstream = git(["-C", source, "remote", "get-url", "origin"], check=False)
        if upstream:
            push_url = upstream
    git(["remote", "remove", "origin"], cwd=rewritten, check=False)
    git(["remote", "add", "origin", push_url], cwd=rewritten)

    print(f"""
=== NEXT STEPS (manual, on purpose) ===
1. Inspect:  cd "{rewritten}"  then  git log --all --format="%an <%ae> | %s" | head -50
2. Check that {email} is linked to your GitHub account (otherwise commits are not attributed to you).
3. Push (overwrites remote history, IRREVERSIBLE without the backup):
     git fetch origin --prune --tags        # picks up any new commits pushed meanwhile
     git push --force-with-lease --all origin
     git push --force-with-lease --tags origin
   --force-with-lease refuses to overwrite a remote that moved since the clone.
   If a branch is protected, temporarily allow force pushes in the GitHub settings.
4. Your local working clone is now stale: re-clone the repository (safest).
5. Keep "{backup}" until you are sure everything is fine.
""")


if __name__ == "__main__":
    main()

# oh-no-my-contributor - install AI-attribution guardrails into the current repo.
# V2: never overrides an existing hook setup unless -Force is passed.
# Idempotent. Run from anywhere inside the target repository:
#   powershell -File install.ps1 [-Force]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$skillDir = Split-Path -Parent $PSScriptRoot
$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { throw "error: not inside a git repository" }
Set-Location $root
$gitDir = (git rev-parse --git-dir)

function Say($m)  { Write-Host $m }
function Warn($m) { Write-Warning $m }

# --- detect existing hook infrastructure -------------------------------------
$existingHooksPath = (git config --get core.hooksPath 2>$null)
$conflicts = @()
# hooksPath already pointing at .githooks is our own previous install,
# not a conflict. Anything else would be bypassed by our hooksPath.
if ($existingHooksPath -and $existingHooksPath -ne '.githooks') { $conflicts += "core.hooksPath=$existingHooksPath" }
if (Test-Path .husky) { $conflicts += ".husky/" }
if ((Test-Path package.json) -and (Get-Content package.json -Raw | Select-String -Quiet '"husky"')) { $conflicts += "husky(package.json)" }
if ((Test-Path lefthook.yml) -or (Test-Path lefthook.yaml)) { $conflicts += "lefthook.yml" }
foreach ($h in 'pre-commit','commit-msg','prepare-commit-msg','post-commit','reference-transaction') {
    if (Test-Path (Join-Path $gitDir "hooks/$h")) { $conflicts += ".git/hooks/$h" }
}

$installHook = $true
if ($conflicts.Count -gt 0 -and -not $Force) {
    $installHook = $false
    Warn "existing hook setup detected: $($conflicts -join ' ')"
    Warn "setting core.hooksPath=.githooks would bypass it. Skipping the git hook."
    Warn "Re-run with -Force to install anyway (previous config is backed up)."
}

if ($installHook) {
    New-Item -ItemType Directory -Force .githooks | Out-Null

    if ($existingHooksPath -and $existingHooksPath -ne '.githooks' -and $Force) {
        Set-Content .githooks/ohnmc.previous-hooks-path $existingHooksPath -Encoding ascii
        Get-ChildItem .githooks -File | Where-Object {
            $_.Name -notin 'prepare-commit-msg','reference-transaction','allowed-identities' -and -not $_.Name.StartsWith('ohnmc.')
        } | ForEach-Object {
            if (-not (Test-Path "$($_.FullName).ohnmc.bak")) { Copy-Item $_.FullName "$($_.FullName).ohnmc.bak" }
        }
    }

    # Never silently overwrite different pre-existing hook files.
    foreach ($hook in 'prepare-commit-msg', 'reference-transaction') {
        $hookPath = Join-Path $root ".githooks/$hook"
        $assetPath = "$skillDir/assets/$hook.sh"
        if ((Test-Path $hookPath) -and -not (Test-Path "$hookPath.ohnmc.bak")) {
            $existing = [System.IO.File]::ReadAllText($hookPath) -replace "`r`n", "`n"
            $fresh = [System.IO.File]::ReadAllText($assetPath) -replace "`r`n", "`n"
            if ($existing -ne $fresh) {
                Copy-Item $hookPath "$hookPath.ohnmc.bak"
                Warn "existing .githooks/$hook differed - backed up to .ohnmc.bak"
            }
        }
        # Normalize to LF: a CRLF shebang breaks the hook on Linux/macOS.
        $hookContent = [System.IO.File]::ReadAllText($assetPath) -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($hookPath, $hookContent, $utf8)
    }

    # Allowlist = the repo owner's current git identities (author + committer).
    function Get-Ident($kind) {
        $raw = (git var $kind 2>$null) -join ''
        if (-not $raw) { return '' }
        return ($raw -replace '\s+\d+\s+[+-]\d{4}$', '').Trim()
    }
    $idents = @((Get-Ident GIT_AUTHOR_IDENT), (Get-Ident GIT_COMMITTER_IDENT) |
                Where-Object { $_ } | Sort-Object -Unique)
    if ($idents.Count -eq 0) {
        Warn "git user.name/user.email are not configured - the identity gate cannot work."
        Warn "Configure them, then re-run this installer. (Instruction block still installed.)"
        $installHook = $false
    } else {
        # WriteAllLines emits CRLF on Windows which breaks grep -x in the
        # hook. Join with LF explicitly.
        [System.IO.File]::WriteAllText(
            (Join-Path $root '.githooks/allowed-identities'),
            (($idents -join "`n") + "`n"),
            (New-Object System.Text.UTF8Encoding($false))
        )
        git config core.hooksPath .githooks
        Say "hooks installed: .githooks/prepare-commit-msg + reference-transaction"
        Say "allowlist:       .githooks/allowed-identities ($($idents.Count) identities)"
    }
}

# --- instruction block in AGENTS.md / CLAUDE.md --------------------------------
$block = Get-Content "$skillDir/assets/ai-attribution-block.md" -Raw -Encoding UTF8
foreach ($f in 'AGENTS.md', 'CLAUDE.md') {
    $path = Join-Path $root $f
    if (Test-Path $path) {
        $content = [System.IO.File]::ReadAllText($path)
        if ($content -match 'oh-no-my-contributor:start') {
            if ($content -notmatch 'oh-no-my-contributor:end') {
                Warn "$f has a start marker but no end marker - leaving it untouched."
                continue
            }
            if (-not (Test-Path "$path.ohnmc.bak")) { Copy-Item $path "$path.ohnmc.bak" }
            $content = [regex]::Replace(
                $content,
                '(?s)<!-- oh-no-my-contributor:start -->.*?<!-- oh-no-my-contributor:end -->',
                $block.TrimEnd()
            )
            [System.IO.File]::WriteAllText($path, $content, $utf8)
        } else {
            if (-not (Test-Path "$path.ohnmc.bak")) { Copy-Item $path "$path.ohnmc.bak" }
            [System.IO.File]::AppendAllText($path, "`n$block", $utf8)
        }
    } else {
        [System.IO.File]::WriteAllText($path, $block, $utf8)
    }
}

Say ""
Say "oh-no-my-contributor installed:"
if ($installHook) { Say "  - hook:    .githooks/prepare-commit-msg + reference-transaction (identity gate + trailer strip)" }
else             { Say "  - hook:    SKIPPED (existing hook setup detected - see warnings)" }
Say "  - rules:   AGENTS.md + CLAUDE.md (oh-no-my-contributor block)"
Say ""
Say "Notes:"
Say "  - core.hooksPath is per-clone: on a fresh clone run 'git config core.hooksPath .githooks' once."
Say "  - .githooks/ and the instruction files should be committed so the team gets them."
Say "  - If core.fileMode is off (Windows), run once after committing:"
Say "      git update-index --chmod=+x .githooks/prepare-commit-msg"
Say "  - Existing history is NOT touched. Clean it with scripts/clean_ai_authorship.py"
if (-not $installHook) { Say "    (manual hook integration needed - see warnings above)." }
Say ""
Say "Uninstall:"
Say "  git config --unset core.hooksPath"
Say "  remove .githooks/ (only if this installer created it)"
Say "  delete <!-- oh-no-my-contributor:start/end --> blocks from AGENTS.md / CLAUDE.md"
Say "  .ohnmc.bak files hold pre-install copies of edited files."

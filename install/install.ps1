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

$injectAlways = @('AGENTS.md', 'CLAUDE.md')
$injectIfExists = @('GEMINI.md', '.cursorrules', '.windsurfrules', '.github/copilot-instructions.md')

$existingHooksPath = (git config --get core.hooksPath 2>$null)
$conflicts = @()
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
        $hookContent = [System.IO.File]::ReadAllText($assetPath) -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($hookPath, $hookContent, $utf8)
    }

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

$block = Get-Content "$skillDir/assets/ai-attribution-block.md" -Raw -Encoding UTF8
function Inject-Block($f) {
    $path = Join-Path $root $f
    if (Test-Path $path) {
        $content = [System.IO.File]::ReadAllText($path)
        if ($content -match 'oh-no-my-contributor:start') {
            if ($content -notmatch 'oh-no-my-contributor:end') {
                Warn "$f has a start marker but no end marker - leaving it untouched."
                return
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

foreach ($f in $injectAlways) { Inject-Block $f }
foreach ($f in $injectIfExists) { if (Test-Path (Join-Path $root $f)) { Inject-Block $f } }

Say ""
Say "oh-no-my-contributor installed:"
if ($installHook) { Say "  - hook:    .githooks/prepare-commit-msg + reference-transaction (identity gate + trailer strip)" }
else             { Say "  - hook:    SKIPPED (existing hook setup detected - see warnings)" }
Say "  - rules:   instruction block in agent instruction files"
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
Say "  delete <!-- oh-no-my-contributor:start/end --> blocks from instruction files"
Say "  .ohnmc.bak files hold pre-install copies of edited files."

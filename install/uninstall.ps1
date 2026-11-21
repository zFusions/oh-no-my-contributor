$ErrorActionPreference = 'Stop'

$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { throw "error: not inside a git repository" }
Set-Location $root

function Say($m)  { Write-Host $m }
function Warn($m) { Write-Warning $m }

$currentHooksPath = (git config --get core.hooksPath 2>$null)
if (Test-Path .githooks) {
    $prevFile = '.githooks/ohnmc.previous-hooks-path'
    if (Test-Path $prevFile) {
        $prev = (Get-Content $prevFile -Raw).Trim()
        git config core.hooksPath $prev
        Say "core.hooksPath restored to: $prev"
    } elseif ($currentHooksPath -eq '.githooks') {
        git config --unset core.hooksPath
        Say "core.hooksPath unset (was .githooks)"
    } else {
        Warn "core.hooksPath is '$currentHooksPath', not ours - left untouched."
    }

    Remove-Item .githooks/prepare-commit-msg, .githooks/reference-transaction, `
               .githooks/allowed-identities, .githooks/ohnmc.previous-hooks-path `
               -ErrorAction SilentlyContinue
    Remove-Item .githooks/*.ohnmc.bak -ErrorAction SilentlyContinue
    Remove-Item .githooks/prepare-commit-msg.ohnmc.bak -ErrorAction SilentlyContinue

    if (-not (Get-ChildItem .githooks -Force -ErrorAction SilentlyContinue)) {
        Remove-Item .githooks
        Say "removed empty .githooks/"
    } else {
        Warn ".githooks/ still contains other files - left in place."
    }
} else {
    Say "no .githooks/ directory found - hook part already absent."
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$targets = @('AGENTS.md', 'CLAUDE.md', 'GEMINI.md', '.cursorrules', '.windsurfrules', '.github/copilot-instructions.md')
foreach ($f in $targets) {
    $path = Join-Path $root $f
    if (-not (Test-Path $path)) { continue }
    $content = [System.IO.File]::ReadAllText($path)
    if ($content -match 'oh-no-my-contributor:start') {
        if ($content -notmatch 'oh-no-my-contributor:end') {
            Warn "$f has a start marker but no end marker - left untouched."
            continue
        }
        $content = [regex]::Replace(
            $content,
            '(?s)\r?\n?<!-- oh-no-my-contributor:start -->.*?<!-- oh-no-my-contributor:end -->\r?\n?',
            ''
        )
        [System.IO.File]::WriteAllText($path, $content, $utf8)
        Say "removed oh-no-my-contributor block from $f"
    }
}

Say ""
Say "oh-no-my-contributor uninstalled."
Say "Note: *.ohnmc.bak files were kept - delete them manually if unneeded."
Say "Note: history already rewritten stays rewritten; this only removes the guardrails."

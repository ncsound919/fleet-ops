# Propagate the fleet-audit workflow into every owned repo in the ecosystem.
#
# Only touches repos whose origin is under github.com/ncsound919 (skips vendored
# upstream clones such as degoog, gocron, maildun, openpost, filmcraft, and the
# artcraft vendor repos). Default is DRY RUN - pass -Apply to write.
#
# Usage:
#   powershell -File propagate-fleet-audit.ps1                 # dry run, lists targets
#   powershell -File propagate-fleet-audit.ps1 -Apply          # writes the file into each repo
#   powershell -File propagate-fleet-audit.ps1 -Apply -Commit  # also commits on a branch

[CmdletBinding()]
param(
  [string]$Root = 'C:\Users\User\Downloads\BUSINESS',
  [switch]$Apply,
  [switch]$Commit,
  [string]$Owner = 'ncsound919'
)

$ErrorActionPreference = 'Stop'
$template = Join-Path $PSScriptRoot '..\templates\fleet-audit.yml' | Resolve-Path
$content  = Get-Content -LiteralPath $template -Raw

$repos = Get-ChildItem -Path $Root -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue |
  Where-Object { Test-Path (Join-Path $_.FullName '.git') -PathType Container } |
  Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
  Select-Object -ExpandProperty FullName -Unique

$targets = @()
foreach ($d in $repos) {
  $origin = (git -C $d remote get-url origin 2>$null)
  if ($origin -and $origin -match [regex]::Escape("github.com/$Owner/")) { $targets += $d }
}

if ($targets.Count -eq 0) { throw "no owned repos found under $Root (owner $Owner)" }
Write-Host "owned repos: $($targets.Count)" -ForegroundColor Cyan

foreach ($d in $targets) {
  $dest = Join-Path $d '.github\workflows\fleet-audit.yml'
  $rel  = $d.Replace($Root, '.')
  if (Test-Path -LiteralPath $dest) {
    $same = (Get-Content -LiteralPath $dest -Raw) -eq $content
    Write-Host ("  [skip] {0} already present{1}" -f $rel, $(if ($same) { '' } else { ' (DIFFERS - review)' }))
    continue
  }
  if (-not $Apply) { Write-Host "  [dry]  would write $rel\.github\workflows\fleet-audit.yml"; continue }

  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  Set-Content -LiteralPath $dest -Value $content -Encoding UTF8
  Write-Host "  [write] $rel" -ForegroundColor Green

  if ($Commit) {
    git -C $d add .github/workflows/fleet-audit.yml
    git -C $d commit -m "ci: add fleet-audit workflow (Ecosystem Watch)" | Out-Null
    Write-Host "  [commit] $rel" -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host $(if ($Apply) { "done." } else { "dry run complete - re-run with -Apply to write." }) -ForegroundColor Cyan

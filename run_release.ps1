
# run_release.ps1
# Usage:
#   .\run_release.ps1 baseline
#   .\run_release.ps1 migrate
#   Updated to run one or the other with the AI review 02/17/2026

# run_release.ps1
# Usage:
#   .\run_release.ps1 baseline
#   .\run_release.ps1 migrate

[CmdletBinding()]
param(
  [Parameter(Position=0, Mandatory=$true)]
  [ValidateSet("baseline","migrate")]
  [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\00_env.ps1"

Write-Host "=== DEMO START ==="

$baselineScript = Join-Path $PSScriptRoot "10_baseline.ps1"
$reviewScript   = Join-Path $PSScriptRoot "20_review_migrations.ps1"
$migrateScript  = Join-Path $PSScriptRoot "30_migrate_if_pass.ps1"

function Run-Script {
  param([Parameter(Mandatory=$true)][string]$Path)

  if (-not (Test-Path $Path)) { throw "Script not found: $Path" }

  Write-Host "`n=== Running: $Path ==="
  & $Path
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

switch ($Action) {
  "baseline" {
    Run-Script $baselineScript
    exit 0
  }

  "migrate" {
    Run-Script $reviewScript
    & $migrateScript
    exit $LASTEXITCODE
  }
}

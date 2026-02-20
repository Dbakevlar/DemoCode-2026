. "$PSScriptRoot\00_env.ps1"

# Normalize Flyway settings: prefer global, fall back to env, then local variables
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_URL))      { $global:FLYWAY_URL      = $env:FLYWAY_URL }
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_USER))     { $global:FLYWAY_USER     = $env:FLYWAY_USER }
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_PASSWORD)) { $global:FLYWAY_PASSWORD = $env:FLYWAY_PASSWORD }

# If your env file sets non-global vars, capture those too
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_URL) -and -not [string]::IsNullOrWhiteSpace($FLYWAY_URL)) { $global:FLYWAY_URL = $FLYWAY_URL }
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_USER) -and -not [string]::IsNullOrWhiteSpace($FLYWAY_USER)) { $global:FLYWAY_USER = $FLYWAY_USER }
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_PASSWORD) -and -not [string]::IsNullOrWhiteSpace($FLYWAY_PASSWORD)) { $global:FLYWAY_PASSWORD = $FLYWAY_PASSWORD }

function Invoke-OllamaReview {
  param(
    [Parameter(Mandatory=$true)][string]$SqlText,
    [Parameter(Mandatory=$true)][string]$MigrationName
  )

  $system = @"
You are a senior PostgreSQL 17 SQL reviewer.

Return a HUMAN-READABLE REVIEW ONLY (no JSON, no markdown fences, no code blocks).
Your output MUST follow this exact structure:

VERDICT: PASS|FAIL
SUMMARY:
- <one to three bullets>

SYNTAX ISSUES:
- <bullet per issue, or "None">

RISKS:
- <severity: LOW|MEDIUM|HIGH> <issue> | <recommendation>
- (or "None")

MISSING INDEXES:
- <table>(<col1,col2>) <index_type> | <why> | <ddl>
- (or "None")

PERFORMANCE:
- <issue> | <recommendation>
- (or "None")

Rules:
- FAIL if syntax errors are present OR the migration is unsafe without key mitigations.
- Prefer Postgres-safe patterns (CONCURRENTLY where appropriate, avoid long locks, call out rewrites).
- Be concise and actionable.
"@

  $user = @"
Review Flyway migration: $MigrationName

SQL:
$SqlText
"@

  $payload = @{
    model = $global:OLLAMA_MODEL
    stream = $false
    messages = @(
      @{ role = "system"; content = $system },
      @{ role = "user"; content = $user }
    )
    options = @{
      temperature = 0.2
    }
  } | ConvertTo-Json -Depth 20

  try {
    $resp = Invoke-RestMethod -Method Post -Uri "$($global:OLLAMA_URL)/api/chat" -ContentType "application/json" -Body $payload -TimeoutSec 180
    return $resp.message.content
  }
  catch {
    throw "Ollama call failed for $MigrationName : $($_.Exception.Message)"
  }
}

function Get-VerdictFromText {
  param(
    [Parameter(Mandatory=$true)][string]$ReviewText
  )

  # Find a line like: VERDICT: PASS or VERDICT: FAIL (case-insensitive)
  $m = [regex]::Match($ReviewText, '(?im)^\s*VERDICT\s*:\s*(PASS|FAIL)\s*$')
  if (-not $m.Success) { return $null }
  return $m.Groups[1].Value.ToUpperInvariant()
}

function Save-ReportText {
  param(
    [Parameter(Mandatory=$true)][string]$MigrationName,
    [Parameter(Mandatory=$true)][string]$ReviewText,
    [Parameter(Mandatory=$true)][string]$Verdict
  )

  $ts = Get-Date -Format "yyyyMMdd-HHmmss"

  if (-not (Test-Path -LiteralPath $global:REPORT_DIR)) {
    New-Item -ItemType Directory -Path $global:REPORT_DIR -Force | Out-Null
  }

  $Decision = $Verdict

  # Plain text report
  $txtPath = Join-Path $global:REPORT_DIR "$ts`_$MigrationName.txt"
  @(
    "Review: $MigrationName"
    "Timestamp: $ts"
    "VERDICT: $Verdict"
    "DECISION: $Decision"
    ""
    $ReviewText.TrimEnd()
    ""
  ) | Out-File -FilePath $txtPath -Encoding utf8

  # Markdown copy
  $mdPath = Join-Path $global:REPORT_DIR "$ts`_$MigrationName.md"

  @(
    "# Review: $MigrationName"
    ""
    "**Timestamp:** $ts"
    "**Verdict:** $Verdict"
    "**Decision:** $Decision"
    ""
    '```text'
    $ReviewText.TrimEnd()
    '```'
    ""
  ) | Out-File -FilePath $mdPath -Encoding utf8

  Write-Host "Report written: $txtPath"
  Write-Host "Report written: $mdPath"
}


# ---- Main ----
$migrations = Get-ChildItem -Path $global:SQL_MIGRATIONS_DIR -Filter "V*.sql" | Sort-Object Name
if (-not $migrations) { throw "No migrations found in $($global:SQL_MIGRATIONS_DIR)" }

$anyFail = $false

foreach ($m in $migrations) {
  $name = [IO.Path]::GetFileNameWithoutExtension($m.Name)
  Write-Host "== Reviewing $name =="

  $sql = Get-Content -Path $m.FullName -Raw

  $reviewText = Invoke-OllamaReview -SqlText $sql -MigrationName $name

  # Fail-closed verdict extraction
  $verdict = Get-VerdictFromText -ReviewText $reviewText
  if (-not $verdict) {
    $verdict = "FAIL"
    $reviewText = @"
VERDICT: FAIL
SUMMARY:
- Reviewer output did not include a valid verdict line. Failing closed.

SYNTAX ISSUES:
- Unable to determine (invalid review format)

RISKS:
- HIGH Reviewer output not machine-verifiable | Fix prompt/model to always emit "VERDICT: PASS|FAIL" as the first line.

MISSING INDEXES:
- None

PERFORMANCE:
- None

RAW OUTPUT (first 500 chars):
$($reviewText.Substring(0, [Math]::Min(500, $reviewText.Length)))
"@
  }

  Save-ReportText -MigrationName $name -ReviewText $reviewText -Verdict $verdict

  if ($verdict -ne "PASS") {
    $anyFail = $true
    Write-Host "FAIL: $name" -ForegroundColor Red
  } else {
    Write-Host "PASS: $name" -ForegroundColor Green
  }
}

if ($anyFail) {
  Write-Host "One or more migrations FAILED review. Blocking Flyway migrate." -ForegroundColor Red
  exit 1
}

Write-Host "All migrations PASSED review. Migration may proceed." -ForegroundColor Green

# Example: run Flyway only if all reviews passed

# Resolve Flyway from PATH
$flywayCmd = Get-Command flyway -ErrorAction SilentlyContinue
if (-not $flywayCmd) {
  throw "Flyway not found on PATH in this PowerShell session."
}

# Project root assumed: script in \ps\, config in project root
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$configPath  = Join-Path $projectRoot "flyway.conf"

if (-not (Test-Path -LiteralPath $configPath)) {
  throw "flyway.conf not found at: $configPath"
}

# Detect which config flag exists in this Flyway build
$helpText = & $flywayCmd.Source -h 2>&1
if ($helpText -match "configFiles") {
  $configArg = "-configFiles=$configPath"
}
elseif ($helpText -match "configFile") {
  $configArg = "-configFile=$configPath"
}
else {
  throw "This Flyway build does not appear to support configFile(s) CLI parameter."
}
Write-Host "DEBUG: global URL  = '$($global:FLYWAY_URL)'" 
Write-Host "DEBUG: global USER = '$($global:FLYWAY_USER)'" 
Write-Host "DEBUG: global PASS set? " -NoNewline
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_PASSWORD)) { Write-Host "NO" } else { Write-Host "YES" }

# Optional sanity checks (helps catch empty env vars)
if ([string]::IsNullOrWhiteSpace($FLYWAY_URL))  { throw "FLYWAY_URL is empty" }
if ([string]::IsNullOrWhiteSpace($FLYWAY_USER)) { throw "FLYWAY_USER is empty" }
if ([string]::IsNullOrWhiteSpace($FLYWAY_PASSWORD)) { throw "FLYWAY_PASSWORD is empty" }

Push-Location $projectRoot
try {
  # IMPORTANT: options first, command last
  & $flywayCmd.Source `
    $configArg `
    "-url=$($global:FLYWAY_URL)" `
    "-user=$($global:FLYWAY_USER)" `
    "-password=$($global:FLYWAY_PASSWORD)" `
    migrate
}
finally {
  Pop-Location
}

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0

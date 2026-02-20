. "$PSScriptRoot\00_env.ps1"

$baselineFile = Join-Path $global:SQL_BASELINE_DIR "V1__baseline.sql"

Write-Host "== Baseline: generating baseline from $($global:PG_SOURCE_DB) (schema-only) =="

# Requires pg_dump in PATH (PostgreSQL bin folder)
$env:PGPASSWORD = $global:PG_PASSWORD

Write-Host "pg_dump version:"
pg_dump --version

Write-Host "Testing DB connectivity with psql:"
psql --version

$env:PGPASSWORD = $global:PG_PASSWORD
psql -h $global:PG_HOST -p $global:PG_PORT -U $global:PG_USER -d $global:PG_SOURCE_DB -c "SELECT 1;"
Write-Host "psql exit code: $LASTEXITCODE"

$baselineFile = Join-Path $global:SQL_BASELINE_DIR "V1__baseline.sql"
New-Item -ItemType Directory -Force -Path $global:SQL_BASELINE_DIR | Out-Null

# Ensure old file isn't read-only / locked
if (Test-Path $baselineFile) { Remove-Item $baselineFile -Force }

$env:PGPASSWORD = $global:PG_PASSWORD

$args = @(
  "--host", $global:PG_HOST,
  "--port", $global:PG_PORT,
  "--username", $global:PG_USER,
  "--dbname", $global:PG_SOURCE_DB,
  "--schema-only",
  "--no-owner",
  "--no-privileges",
  "--file", $baselineFile
)

Write-Host "Running: pg_dump $($args -join ' ')"

# Capture stderr to see the real reason
$stderrFile = Join-Path $global:REPORT_DIR "pg_dump_stderr.txt"
$stdoutFile = Join-Path $global:REPORT_DIR "pg_dump_stdout.txt"

& pg_dump @args 1> $stdoutFile 2> $stderrFile
$code = $LASTEXITCODE

Write-Host "pg_dump exit code: $code"
if ($code -ne 0) {
  Write-Host "---- pg_dump stderr ----" -ForegroundColor Yellow
  Get-Content $stderrFile -Raw | Write-Host
  throw "pg_dump failed. See $stderrFile"
}

Write-Host "Baseline written to: $baselineFile"


Write-Host "== Applying baseline to $($global:PG_DEMO_DB) using Flyway =="

# Remove SET client_encoding from any baseline scripts in the configured baseline dir (no hardcoded filename)
$baselineDir = $global:SQL_BASELINE_DIR

if (-not (Test-Path $baselineDir)) {
  throw "Baseline directory not found: $baselineDir"
}

$baselineFiles = @(Get-ChildItem -Path $baselineDir -Filter "V*__*.sql" -File)

$baselineFiles = @(Get-ChildItem -Path $baselineDir -Filter "V*__*.sql" -File -ErrorAction SilentlyContinue)

if (-not $baselineFiles -or $baselineFiles.Count -eq 0) {
  throw "No baseline migration files found in $baselineDir"
}

foreach ($file in $baselineFiles) {
  Write-Host "Normalizing baseline file UTF-8: $($file.FullName)"
  (Get-Content $file.FullName) |
    Where-Object { $_ -notmatch "^\s*SET\s+client_encoding\s*=" } |
    Set-Content $file.FullName -Encoding UTF8
}

# Flyway migrate (your existing invocation)
$flywayUrl = "jdbc:postgresql://$($global:PG_HOST)`:$($global:PG_PORT)/$($global:PG_DEMO_DB)"

flyway `
  "-configFiles=$($global:FLYWAY_CONF)" `
  "-url=$flywayUrl" `
  "-locations=filesystem:$($global:SQL_BASELINE_DIR)" `
  migrate

if ($LASTEXITCODE -ne 0) {
  throw "Flyway baseline migrate failed."
}

Write-Host "Baseline applied successfully."

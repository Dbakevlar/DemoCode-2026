# 00_env.ps1
# Purpose:
# - Initialize UTF-8
# - Centralize env vars + defaults
#   Ensure the PASSWORD IS SET:  $env:FLYWAY_PASSWORD = "
# - Build Flyway JDBC URL dynamically from PG_DEMO_DB (target) or PG_SOURCE_DB (source)
#   using env vars: PG_DEMO_DB / PG_SOURCE (per your scenario)
# - Keep secrets out of the repo (prefer env vars)

# Force UTF-8 for this PowerShell session
chcp 65001 | Out-Null
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# PostgreSQL clients
$env:PGCLIENTENCODING = "UTF8"
Write-Host "UTF-8 environment initialized"

# -------------------------------
# Repo paths (anchored to this file)
# -------------------------------
$global:START_DIR          = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$global:FLYWAY_CONF        = Join-Path $global:START_DIR "ps\flyway.conf"
$global:SQL_BASELINE_DIR   = Join-Path $global:START_DIR "ps\flyway\sql\baseline"
$global:SQL_MIGRATIONS_DIR = Join-Path $global:START_DIR "ps\flyway\sql\migrations"

# -------------------------------
# DB names
# Scenario:
# - Target DB name: PG_DEMO_DB (environment variable)
# - Source DB name: PG_SOURCE   (environment variable)
# Provide safe local defaults if env vars aren't set.
# -------------------------------
$global:PG_DEMO_DB   = if (-not [string]::IsNullOrWhiteSpace($env:PG_DEMO_DB)) { $env:PG_DEMO_DB } else { "pg_demo" }
$global:PG_SOURCE_DB = if (-not [string]::IsNullOrWhiteSpace($env:PG_SOURCE))  { $env:PG_SOURCE }  else { "pg_source" }

# -------------------------------
# Connection / auth (shared)
# Prefer env vars where available; default for local dev.
# -------------------------------
$global:PG_HOST = if (-not [string]::IsNullOrWhiteSpace($env:PG_HOST)) { $env:PG_HOST } else { "localhost" }
$global:PG_PORT = if (-not [string]::IsNullOrWhiteSpace($env:PG_PORT)) { [int]$env:PG_PORT } else { 5432 }

# Prefer Flyway env vars for Flyway, but allow falling back to PG_* if you set those instead.
$global:FLYWAY_USER = if (-not [string]::IsNullOrWhiteSpace($env:FLYWAY_USER)) { $env:FLYWAY_USER }
                      elseif (-not [string]::IsNullOrWhiteSpace($env:PG_USER))  { $env:PG_USER }
                      else { "postgres" }

# Password: do NOT hardcode. Prefer FLYWAY_PASSWORD, else PGPASSWORD/PG_PASSWORD if you use those.
$global:FLYWAY_PASSWORD = if (-not [string]::IsNullOrWhiteSpace($env:FLYWAY_PASSWORD)) { $env:FLYWAY_PASSWORD }
                          elseif (-not [string]::IsNullOrWhiteSpace($env:PGPASSWORD))  { $env:PGPASSWORD }
                          elseif (-not [string]::IsNullOrWhiteSpace($env:PG_PASSWORD)) { $env:PG_PASSWORD }
                          else { "" }

# Keep PG_* in sync for other tooling if you want (psql, pg_dump, etc.)
$global:PG_USER     = $global:FLYWAY_USER
$global:PG_PASSWORD = $global:FLYWAY_PASSWORD

# -------------------------------
# Flyway URL builder
# Choose which DB Flyway targets:
# - Set $env:FLYWAY_DB_ROLE to "DEMO" or "SOURCE" (defaults to DEMO)
# - Or set $env:FLYWAY_DB_NAME explicitly to override the choice
# - Or set $env:FLYWAY_URL explicitly to override everything (CI can do this)
# -------------------------------
$flywayDbRole = if (-not [string]::IsNullOrWhiteSpace($env:FLYWAY_DB_ROLE)) { $env:FLYWAY_DB_ROLE.ToUpperInvariant() } else { "DEMO" }

if (-not [string]::IsNullOrWhiteSpace($env:FLYWAY_URL)) {
    # Explicit full override (CI / advanced scenarios)
    $global:FLYWAY_URL = $env:FLYWAY_URL
}
else {
    # Decide DB name
    if (-not [string]::IsNullOrWhiteSpace($env:FLYWAY_DB_NAME)) {
        $dbName = $env:FLYWAY_DB_NAME
    }
    else {
        switch ($flywayDbRole) {
            "SOURCE" { $dbName = $global:PG_SOURCE_DB }
            "DEMO"   { $dbName = $global:PG_DEMO_DB }
            default  { throw "Invalid FLYWAY_DB_ROLE='$flywayDbRole' (use DEMO or SOURCE)" }
        }
    }

    if ([string]::IsNullOrWhiteSpace($dbName)) { throw "Flyway database name resolved empty. Check PG_DEMO_DB / PG_SOURCE (env) or defaults." }

    # Note: backtick escapes ':' in interpolated strings in PowerShell
    $global:FLYWAY_URL = "jdbc:postgresql://$($global:PG_HOST)`:$($global:PG_PORT)/$dbName"
}

# -------------------------------
# Validation
# If your local PG is configured for trust, you can skip password locally.
# Require password in CI by default.
# -------------------------------
$IsCI = -not [string]::IsNullOrWhiteSpace($env:CI)

if ([string]::IsNullOrWhiteSpace($global:FLYWAY_URL))  { throw "FLYWAY_URL is empty (00_env.ps1)" }
if ([string]::IsNullOrWhiteSpace($global:FLYWAY_USER)) { throw "FLYWAY_USER is empty (00_env.ps1)" }

if ($IsCI -and [string]::IsNullOrWhiteSpace($global:FLYWAY_PASSWORD)) {
    throw "FLYWAY_PASSWORD is empty (00_env.ps1) - required in CI"
}

# -------------------------------
# Ollama
# -------------------------------
$global:OLLAMA_URL   = if (-not [string]::IsNullOrWhiteSpace($env:OLLAMA_URL)) { $env:OLLAMA_URL } else { "http://localhost:11434" }
$global:OLLAMA_MODEL = if (-not [string]::IsNullOrWhiteSpace($env:OLLAMA_MODEL)) { $env:OLLAMA_MODEL } else { "qwen2.5-coder:latest" }

# -------------------------------
# Output
# -------------------------------
$global:REPORT_DIR = Join-Path $PSScriptRoot "reports"
New-Item -ItemType Directory -Force -Path $global:REPORT_DIR | Out-Null

# Optional: quick debug (comment out when stable)
# Write-Host "Flyway role=$flywayDbRole URL=$($global:FLYWAY_URL) User=$($global:FLYWAY_USER) PassSet=$(-not [string]::IsNullOrWhiteSpace($global:FLYWAY_PASSWORD))"

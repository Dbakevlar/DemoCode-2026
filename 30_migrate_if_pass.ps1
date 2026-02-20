. "$PSScriptRoot\00_env.ps1"

Write-Host "== Running Ollama review gate =="
& "$PSScriptRoot\20_review_migrations.ps1"
if ($LASTEXITCODE -ne 0) {
  Write-Host "Gate failed. Not running Flyway migrate." -ForegroundColor Red
  exit 1
}

Write-Host "== Gate passed. Running Flyway migrate against $($global:PG_DEMO_DB) =="

flyway `
  "-configFiles=$($global:FLYWAY_CONF)" `
  "-url=jdbc:postgresql://$($global:PG_HOST):$($global:PG_PORT)/$($global:PG_DEMO_DB)?charSet=UTF8" `
  "-locations=filesystem:$($global:SQL_MIGRATIONS_DIR)" `
  migrate

if ($LASTEXITCODE -ne 0) {
  Write-Host "Flyway migrate failed." -ForegroundColor Red
  exit 1
}

Write-Host "Flyway migrate succeeded." -ForegroundColor Green
exit 0

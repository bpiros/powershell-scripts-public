# update-all.ps1 — Updateing Scoop managed programs, Winget managed programs, and every other CLI tool

Write-Host "Running custom updates..." -ForegroundColor Cyan

# Android CLI
Write-Host "`n[Android CLI - Update]" -ForegroundColor Yellow
android-cli update

# Add more tools here later, for example:
Write-Host "`n[Scoop - Update]" -ForegroundColor Yellow
scoop update *

# Add more tools here later, for example:
Write-Host "`n[Winget - Update]" -ForegroundColor Yellow
winget upgrade --all

Write-Host "`nAll updates done!" -ForegroundColor Green
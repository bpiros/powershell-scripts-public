# update-custom.ps1 — Add any CLI tools here that are not managed by Scoop

Write-Host "Running custom updates..." -ForegroundColor Cyan

# Android CLI
Write-Host "`n[Android CLI]" -ForegroundColor Yellow
android-cli update

# Add more tools here later, for example:
# Write-Host "`n[Another Tool]" -ForegroundColor Yellow
# another-tool update

Write-Host "`nAll custom updates done!" -ForegroundColor Green
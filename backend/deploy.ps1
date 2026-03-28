# Deploy Clubby Azure Functions (includes /api/auth/signup, /api/auth/login, /api/auth/session).
# Prereqs: Azure CLI (`az login`), resource-group access. Uses zip deploy + Oryx npm install on the app.
param(
    [string]$FunctionAppName = "zello-func-11159",
    [string]$ResourceGroup = "zello-mvp-rg-11159"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$zip = Join-Path (Split-Path $PSScriptRoot -Parent) "fn_deploy.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "host.json", "package.json", "package-lock.json", "index.js", "shared" -DestinationPath $zip -Force

Write-Host "Uploading $zip to $FunctionAppName ..."
az functionapp deployment source config-zip --resource-group $ResourceGroup --name $FunctionAppName --src $zip
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Done. Signup URL (note spelling: signup not singup):"
Write-Host "  POST https://$FunctionAppName.azurewebsites.net/api/auth/signup"
Write-Host '  Body: {"username":"testuser","password":"testpass12"}'

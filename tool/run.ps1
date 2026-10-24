# Runs NOIR on Windows with the local (gitignored) Google OAuth configuration.
#   ./tool/run.ps1            debug run
#   ./tool/run.ps1 -Release   release build into build\windows\x64\runner\Release
param([switch]$Release)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$config = 'config/oauth.local.json'
$defines = @()
if (Test-Path $config) { $defines = @("--dart-define-from-file=$config") }
else { Write-Warning "$config not found: Google sign-in will be unavailable (see config.example/)." }
if ($Release) { flutter build windows --release @defines }
else { flutter run -d windows @defines }

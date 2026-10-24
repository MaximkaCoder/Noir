# Runs NOIR on Windows with the local (gitignored) Google OAuth configuration.
#   ./tool/run.ps1            debug run
#   ./tool/run.ps1 -Release   release build into build\windows\x64\runner\Release
# Builds the optional local entrypoint lib/private/main.dart (never committed)
# when it exists, otherwise lib/main.dart.
param([switch]$Release)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$config = 'config/oauth.local.json'
$defines = @()
if (Test-Path $config) { $defines = @("--dart-define-from-file=$config") }
else { Write-Warning "$config not found: Google sign-in will be unavailable (see config.example/)." }
$target = 'lib/private/main.dart'
if (Test-Path $target) { $defines += @('-t', $target) }
if ($Release) { flutter build windows --release @defines }
else { flutter run -d windows @defines }

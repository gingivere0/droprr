# Publishes the Windows app into deploy\<yyyyMMdd-HHmmss>\ and marks it ready. A Droprr running from an
# earlier deploy folder notices within a few seconds and restarts onto the new build by itself.
# Usage, from anywhere: powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$version = Get-Date -Format "yyyyMMdd-HHmmss"
$target = Join-Path $repo "deploy\$version"

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnet) { $dotnet.Source } else { Join-Path $env:ProgramFiles "dotnet\dotnet.exe" }

& $dotnet publish (Join-Path $repo "src\Droprr.Windows\Droprr.Windows.csproj") -c Release --no-self-contained -o $target -nologo -v q
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

# Written last, so a half-copied build is never picked up.
Set-Content -Path (Join-Path $target "ready") -Value $version
"Deployed $target\Droprr.exe"

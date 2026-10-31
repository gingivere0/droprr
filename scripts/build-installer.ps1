# Builds the Windows installer: dist\DroprrSetup-<version>.exe, one self-contained exe (no .NET install needed).
# Droprr is its own installer (src\Droprr.Windows\Shell\Installer.cs): named DroprrSetup*.exe, it installs itself per user
# into %LOCALAPPDATA%\Programs\Droprr. The exe isn't signed, so SmartScreen warns the first time it's run.
# Usage, from anywhere: powershell -ExecutionPolicy Bypass -File scripts\build-installer.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$project = Join-Path $repo "src\Droprr.Windows\Droprr.Windows.csproj"
$publish = Join-Path $repo "dist\publish"

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnet) { $dotnet.Source } else { Join-Path $env:ProgramFiles "dotnet\dotnet.exe" }

if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
& $dotnet publish $project -c Release -r win-x64 --self-contained -o $publish -nologo -v q `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

$version = ([xml](Get-Content $project)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
$setup = Join-Path $repo "dist\DroprrSetup-$version.exe"
Copy-Item (Join-Path $publish "Droprr.exe") $setup -Force
"Built $setup ($([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB)"

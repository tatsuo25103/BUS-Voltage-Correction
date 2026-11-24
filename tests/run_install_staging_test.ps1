param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$testRoot = Join-Path $ProjectRoot "tmp\install_staging_test"
$stagingRoot = Join-Path $testRoot "package"
$installRoot = Join-Path $testRoot "installed"

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

$files = @(
    @{ Source = "BUS_Voltage_Correction.ps1"; Destination = "BUS_Voltage_Correction.ps1" },
    @{ Source = "open_desktop_gui.bat"; Destination = "open_desktop_gui.bat" },
    @{ Source = "installer\install.ps1"; Destination = "install.ps1" },
    @{ Source = "installer\uninstall.ps1"; Destination = "uninstall.ps1" },
    @{ Source = "README.md"; Destination = "README.md" },
    @{ Source = "assets\mes_logo_light.png"; Destination = "mes_logo_light.png" }
)
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot $file.Source) -Destination (Join-Path $stagingRoot $file.Destination) -Force
}

try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stagingRoot "install.ps1") `
        -InstallRoot $installRoot -SkipShortcuts -SkipRegistration
    if ($LASTEXITCODE -ne 0) { throw "Staged installer returned exit code $LASTEXITCODE." }

    foreach ($required in @(
        "BUS_Voltage_Correction.ps1",
        "open_desktop_gui.bat",
        "uninstall.ps1",
        "README.md",
        "assets\mes_logo_light.png"
    )) {
        $path = Join-Path $installRoot $required
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Installed file missing: $required" }
    }

    $installedScript = Get-Content -LiteralPath (Join-Path $installRoot "BUS_Voltage_Correction.ps1") -Raw
    if ($installedScript -notmatch '\$script:AppVersion\s*=\s*"0\.8\.1"') {
        throw "Installed application does not report V0.8.1."
    }
    $launcher = Get-Content -LiteralPath (Join-Path $installRoot "open_desktop_gui.bat") -Raw
    if ($launcher -notmatch 'BUS_Voltage_Correction\.ps1') {
        throw "Installed launcher does not target the production script."
    }

    Write-Host "PASS: clean staged installation contains the V0.8.1 production files." -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

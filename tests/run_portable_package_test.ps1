param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Version = "0.8.1"
)

$ErrorActionPreference = "Stop"
$zipPath = Join-Path $ProjectRoot "release\BUS_Voltage_Correction_Portable_V$Version.zip"
$testRoot = Join-Path $ProjectRoot "tmp\portable_package_test"
$packageRoot = Join-Path $testRoot "BUS_Voltage_Correction_Portable_V$Version"

if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "Portable ZIP is missing: $zipPath"
}
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $testRoot -Force
    foreach ($required in @(
        "BUS_Voltage_Correction.ps1",
        "BUS Voltage Correction.vbs",
        "open_desktop_gui.bat",
        "README_PORTABLE.txt",
        "README_PORTABLE.zh-TW.txt",
        "assets\mes_logo_light.png",
        "docs\RELEASE_NOTES_V0.8.1.md",
        "docs\RELEASE_NOTES_V0.8.1.zh-TW.md"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $required) -PathType Leaf)) {
            throw "Portable package file is missing: $required"
        }
    }

    $tokens = $null
    $parseErrors = $null
    $scriptPath = Join-Path $packageRoot "BUS_Voltage_Correction.ps1"
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) { throw "Portable production script has parse errors." }

    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    if ($scriptText -notmatch ('\$script:AppVersion\s*=\s*"' + [regex]::Escape($Version) + '"')) {
        throw "Portable application version does not match V$Version."
    }

    $vbsText = Get-Content -LiteralPath (Join-Path $packageRoot "BUS Voltage Correction.vbs") -Raw
    if ($vbsText -notmatch 'BUS_Voltage_Correction\.ps1') {
        throw "Portable VBS launcher does not target the production script."
    }
    $batText = Get-Content -LiteralPath (Join-Path $packageRoot "open_desktop_gui.bat") -Raw
    if ($batText -notmatch 'BUS_Voltage_Correction\.ps1') {
        throw "Portable BAT launcher does not target the production script."
    }

    Write-Host "PASS: portable V$Version ZIP structure, launchers and production script are valid." -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

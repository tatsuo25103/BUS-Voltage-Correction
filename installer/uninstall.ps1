$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$allowedParent = Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) -ChildPath "Programs"
$resolvedRoot = [System.IO.Path]::GetFullPath($installRoot).TrimEnd('\')
$resolvedParent = [System.IO.Path]::GetFullPath($allowedParent).TrimEnd('\')
if (-not $resolvedRoot.StartsWith($resolvedParent + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to uninstall from an unexpected path: $resolvedRoot"
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)) "BUS Voltage Correction.lnk"
$startMenuPath = Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) -ChildPath "BUS Voltage Correction"
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuPath -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BUSVoltageCorrection" -Recurse -Force -ErrorAction SilentlyContinue

$cleanupPath = Join-Path $env:TEMP ("bus_voltage_correction_cleanup_{0}.cmd" -f ([Guid]::NewGuid().ToString("N")))
$cleanupLines = @(
    "@echo off",
    "timeout /t 2 /nobreak >nul",
    ('rmdir /s /q "{0}"' -f $resolvedRoot),
    'del /q "%~f0"'
)
Set-Content -LiteralPath $cleanupPath -Value $cleanupLines -Encoding ASCII
Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", ('"{0}"' -f $cleanupPath)) -WindowStyle Hidden

[System.Windows.Forms.MessageBox]::Show(
    "BUS Voltage Correction was removed.`r`nCalibration logs were retained in Local AppData.",
    "Uninstall Complete",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null

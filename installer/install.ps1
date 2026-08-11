param(
    [string]$InstallRoot = (Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) -ChildPath "Programs\BUS Voltage Correction"),
    [switch]$SkipShortcuts,
    [switch]$SkipRegistration
)

$ErrorActionPreference = "Stop"
$appScriptName = "BUS_voltage_correction_desktop_test_V0.7.ps1"
$launcherName = "open_desktop_gui_V0.7.bat"

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$assetRoot = Join-Path $InstallRoot "assets"
New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot $appScriptName) -Destination (Join-Path $InstallRoot $appScriptName) -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot $launcherName) -Destination (Join-Path $InstallRoot $launcherName) -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "uninstall.ps1") -Destination (Join-Path $InstallRoot "uninstall.ps1") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "README.md") -Destination (Join-Path $InstallRoot "README.md") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "mes_logo_light.png") -Destination (Join-Path $assetRoot "mes_logo_light.png") -Force

$powershellPath = Join-Path $PSHOME "powershell.exe"
$launchArguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallRoot $appScriptName)
$shell = New-Object -ComObject WScript.Shell

if (-not $SkipShortcuts) {
    $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $startMenuPath = Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) -ChildPath "BUS Voltage Correction"
    New-Item -ItemType Directory -Path $startMenuPath -Force | Out-Null

    foreach ($shortcutPath in @(
        (Join-Path $desktopPath "BUS Voltage Correction.lnk"),
        (Join-Path $startMenuPath "BUS Voltage Correction.lnk")
    )) {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powershellPath
        $shortcut.Arguments = $launchArguments
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.IconLocation = "$env:SystemRoot\System32\imageres.dll,67"
        $shortcut.Description = "BUS Voltage Correction V0.7.1"
        $shortcut.Save()
    }

    $uninstallShortcut = $shell.CreateShortcut((Join-Path $startMenuPath "Uninstall BUS Voltage Correction.lnk"))
    $uninstallShortcut.TargetPath = $powershellPath
    $uninstallShortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallRoot "uninstall.ps1")
    $uninstallShortcut.WorkingDirectory = $InstallRoot
    $uninstallShortcut.Save()
}

if (-not $SkipRegistration) {
    $uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BUSVoltageCorrection"
    New-Item -Path $uninstallKey -Force | Out-Null
    Set-ItemProperty -Path $uninstallKey -Name DisplayName -Value "BUS Voltage Correction"
    Set-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value "0.7.1"
    Set-ItemProperty -Path $uninstallKey -Name Publisher -Value "FSP"
    Set-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $InstallRoot
    Set-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value "$env:SystemRoot\System32\imageres.dll,67"
    Set-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1 -Type DWord
    $uninstallCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallRoot "uninstall.ps1")
    Set-ItemProperty -Path $uninstallKey -Name UninstallString -Value $uninstallCommand
}

exit 0

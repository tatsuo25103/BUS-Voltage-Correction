$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $env:TEMP ("BUSVC_Installer_{0}" -f ([Guid]::NewGuid().ToString("N")))
$stagingRoot = Join-Path $buildRoot "staging"
$releaseRoot = Join-Path $projectRoot "release"
$setupPath = Join-Path $releaseRoot "BUS_Voltage_Correction_Setup_V0.7.1.exe"
$temporarySetupPath = Join-Path $buildRoot "BUS_Voltage_Correction_Setup_V0.7.1.exe"
$sedPath = Join-Path $buildRoot "BUS_Voltage_Correction_V0.7.1.sed"

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

$packageFiles = @(
    @{ Source = (Join-Path $projectRoot "BUS_voltage_correction_desktop_test_V0.7.ps1"); Name = "BUS_voltage_correction_desktop_test_V0.7.ps1" },
    @{ Source = (Join-Path $projectRoot "open_desktop_gui_V0.7.bat"); Name = "open_desktop_gui_V0.7.bat" },
    @{ Source = (Join-Path $PSScriptRoot "install.cmd"); Name = "install.cmd" },
    @{ Source = (Join-Path $PSScriptRoot "install.ps1"); Name = "install.ps1" },
    @{ Source = (Join-Path $PSScriptRoot "uninstall.ps1"); Name = "uninstall.ps1" },
    @{ Source = (Join-Path $projectRoot "assets\mes_logo_light.png"); Name = "mes_logo_light.png" },
    @{ Source = (Join-Path $projectRoot "README.md"); Name = "README.md" }
)
foreach ($file in $packageFiles) {
    if (-not (Test-Path -LiteralPath $file.Source)) { throw "Missing package file: $($file.Source)" }
    Copy-Item -LiteralPath $file.Source -Destination (Join-Path $stagingRoot $file.Name) -Force
}

$fileStringLines = New-Object System.Collections.Generic.List[string]
$sourceFileLines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $packageFiles.Count; $i++) {
    $fileStringLines.Add(('FILE{0}="{1}"' -f $i, $packageFiles[$i].Name))
    $sourceFileLines.Add(('%FILE{0}%=' -f $i))
}

$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=Install BUS Voltage Correction V0.7.1 for the current Windows user?
DisplayLicense=
FinishMessage=BUS Voltage Correction V0.7.1 installation completed.
TargetName=$temporarySetupPath
FriendlyName=BUS Voltage Correction V0.7.1 Setup
AppLaunched=install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
$($fileStringLines -join "`r`n")
[SourceFiles]
SourceFiles0=$stagingRoot\
[SourceFiles0]
$($sourceFileLines -join "`r`n")
"@
Set-Content -LiteralPath $sedPath -Value $sed -Encoding ASCII

$iexpressPath = Join-Path $env:SystemRoot "System32\iexpress.exe"
if (-not (Test-Path -LiteralPath $iexpressPath)) { throw "Windows IExpress was not found: $iexpressPath" }
$process = Start-Process -FilePath $iexpressPath -ArgumentList @("/N", "/Q", $sedPath) -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "IExpress failed with exit code $($process.ExitCode)." }
if (-not (Test-Path -LiteralPath $temporarySetupPath)) { throw "Installer output was not created: $temporarySetupPath" }
Copy-Item -LiteralPath $temporarySetupPath -Destination $setupPath -Force

$hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
Write-Output "Installer: $setupPath"
Write-Output "SHA256: $hash"

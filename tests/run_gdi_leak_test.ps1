param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) "BUS_Voltage_Correction.ps1"),
    [int]$Iterations = 200
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class GuiResourceCounter {
    [DllImport("user32.dll")]
    private static extern int GetGuiResources(IntPtr process, int flags);
    public static int GdiHandles() {
        return GetGuiResources(Process.GetCurrentProcess().Handle, 0);
    }
}
"@

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $SourcePath).Path,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) { throw "Production script has parse errors." }

foreach ($name in @(
    "Get-AnglePoint",
    "Get-AnglePointF",
    "Get-BracketScalePointF",
    "Get-ErrorAngleOffset",
    "Draw-ContactScale",
    "Draw-ContactToleranceSegment",
    "Get-DisplayError",
    "Draw-Bars",
    "Draw-Trend"
)) {
    $definition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Production function not found: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$Theme = @{
    Field = [System.Drawing.Color]::FromArgb(13, 17, 21)
    Border = [System.Drawing.Color]::FromArgb(78, 91, 104)
    Text = [System.Drawing.Color]::FromArgb(226, 235, 244)
    Muted = [System.Drawing.Color]::FromArgb(154, 168, 181)
    Info = [System.Drawing.Color]::FromArgb(94, 157, 255)
    Bad = [System.Drawing.Color]::FromArgb(242, 91, 91)
}
$script:Tolerance = 5.0
$script:Latest = [pscustomobject]@{
    Target = 333.0
    VDSPP = 334.0
    VDSPN = 331.5
    VMCUP = 336.0
    VMCUN = 329.5
}
$script:DisplayedErrors = @{
    VDSPP = 1.0
    VDSPN = -1.5
    VMCUP = 3.0
    VMCUN = -3.5
}
$script:Samples = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 30; $i++) {
    [void]$script:Samples.Add([pscustomobject]@{
        Target = 333.0
        VDSPP = 334.0 + (($i % 3) * 0.1)
        VDSPN = 331.5 + (($i % 2) * 0.1)
        VMCUP = 336.0 - (($i % 4) * 0.1)
        VMCUN = 329.5 + (($i % 5) * 0.1)
    })
}

$form = New-Object System.Windows.Forms.Form
$bitmap = New-Object System.Drawing.Bitmap 1280, 720
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$sender = [pscustomobject]@{ Width = 1280; Height = 720 }
$eventArgs = [pscustomobject]@{ Graphics = $graphics }

try {
    Draw-Bars $sender $eventArgs
    Draw-Trend $sender $eventArgs
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $before = [GuiResourceCounter]::GdiHandles()

    for ($i = 0; $i -lt $Iterations; $i++) {
        Draw-Bars $sender $eventArgs
        Draw-Trend $sender $eventArgs
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $after = [GuiResourceCounter]::GdiHandles()
    $growth = $after - $before
    Write-Host "GDI handles: before=$before after=$after growth=$growth after $Iterations iterations"
    if ($growth -gt 5) { throw "GDI handle growth exceeded the allowed limit." }
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
    $form.Dispose()
}

Write-Host "PASS: repeated gauge and trend rendering does not leak GDI handles." -ForegroundColor Green

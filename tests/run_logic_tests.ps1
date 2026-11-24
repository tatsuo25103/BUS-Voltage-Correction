param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) "BUS_Voltage_Correction.ps1")
)

$ErrorActionPreference = "Stop"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $SourcePath).Path,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Production script has $($parseErrors.Count) parse error(s)."
}

foreach ($name in @(
    "Get-VersionParts",
    "Test-IsNewerVersion",
    "Parse-DeciVolt",
    "Parse-DeciVoltOptional",
    "Test-TelemetryHeader",
    "Get-TargetVoltage",
    "Test-PossibleSinglePhaseSample",
    "Test-MissingAcPhaseSample",
    "Test-ThreePhaseSample",
    "Get-FixedCorrectionStepTenths",
    "Get-CorrectionPlan",
    "Get-ExpectedDirection",
    "Get-ErrorAngleOffset",
    "Test-CorrectionAck"
)) {
    $definition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Production function not found: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$script:AppVersion = "0.8.1"
$script:Tolerance = 5.0
$TargetFactor = 1.414
$SinglePhaseGridMinimumVoltage = 80.0
$SinglePhaseUnusedPhaseMaximumVoltage = 30.0
$CorrectionCommandPrefixes = @{
    VDSPP = "BPVA"
    VDSPN = "BNVA"
    VMCUP = "SBPVA"
    VMCUN = "SBNVA"
}

$script:Passed = 0
$script:Failed = 0
function Assert-True([bool]$condition, [string]$message) {
    if ($condition) {
        $script:Passed += 1
        Write-Host "PASS: $message" -ForegroundColor Green
    } else {
        $script:Failed += 1
        Write-Host "FAIL: $message" -ForegroundColor Red
    }
}

function Assert-Throws([scriptblock]$action, [string]$message) {
    $threw = $false
    try { & $action } catch { $threw = $true }
    Assert-True $threw $message
}

$numericFields = @("^D000", "+03338", "-0005", "3338")
Assert-True ((Parse-DeciVolt $numericFields 1) -eq 333.8) "signed positive decivolt parses"
Assert-True ((Parse-DeciVolt $numericFields 2) -eq -0.5) "signed negative decivolt parses"
Assert-True ((Parse-DeciVoltOptional @("^D000", "") 1) -eq 0.0) "empty optional phase becomes zero"
Assert-Throws { Parse-DeciVolt @("^D000", "ERR3338") 1 } "text-contaminated voltage is rejected"
Assert-Throws { Parse-DeciVolt @("^D000", "+33-38") 1 } "malformed signed voltage is rejected"
Assert-True (Test-TelemetryHeader @("^D1100000", "0000")) "valid telemetry header is accepted"
Assert-True (-not (Test-TelemetryHeader @("ERR1100000", "0000"))) "invalid telemetry header is rejected"

$capturedGs = '^D1100000,0000,0000,0000,0000,000,+00000,2339,2324,2333,4996,0000,0000,0000,2341,2324,2333,4997,,,,030,030,000,0'
$capturedIngs = '^D0560004,0000,0000,0001,0000,0002,3279,3277,3276,3279,0007'
$capturedGsFields = $capturedGs.Split(',')
$capturedIngsFields = $capturedIngs.Split(',')
Assert-True ((Parse-DeciVolt $capturedGsFields 7) -eq 233.9) "captured GS frame remains compatible"
Assert-True ((Parse-DeciVolt $capturedIngsFields 9) -eq 327.9) "captured INGS frame remains compatible"

$single = [pscustomobject]@{ VR = 230.0; VS = 0.0; VT = 0.0 }
$missing = [pscustomobject]@{ VR = 230.0; VS = 0.0; VT = 231.0 }
$three = [pscustomobject]@{ VR = 230.0; VS = 231.0; VT = 229.0 }
$unknown = [pscustomobject]@{ VR = 230.0; VS = 55.0; VT = 231.0 }
Assert-True (Test-PossibleSinglePhaseSample $single) "VR-only input is a possible 5 kW single-phase unit"
Assert-True (-not (Test-MissingAcPhaseSample $single)) "VR-only input is not classified as one missing three-phase leg"
Assert-True (Test-MissingAcPhaseSample $missing) "exactly one near-zero phase is detected"
Assert-True (Test-ThreePhaseSample $three) "three valid phases are detected"
Assert-True (-not (Test-ThreePhaseSample $unknown)) "intermediate phase voltage is not accepted as three-phase"

$script:InverterPhaseMode = "SinglePhase"
Assert-True ([Math]::Abs((Get-TargetVoltage 230 0 0) - 325.22) -lt 0.001) "single-phase target uses VR"
$script:InverterPhaseMode = "ThreePhase"
Assert-True ([Math]::Abs((Get-TargetVoltage 230 235 232) - 332.29) -lt 0.001) "three-phase target uses the maximum phase"

$planHigh = Get-CorrectionPlan "VDSPP" 5.1
$planLow = Get-CorrectionPlan "VMCUN" (-5.1)
Assert-True ($planHigh.Command -eq "BPVA-05") "high error creates a negative fixed 0.5 V command"
Assert-True ($planLow.Command -eq "SBNVA+05") "low error creates a positive fixed 0.5 V command (actual: $($planLow.Command))"
Assert-True ($null -eq (Get-CorrectionPlan "VDSPP" 5.0)) "error at tolerance creates no command"

Assert-True ((Get-ErrorAngleOffset 5.0) -eq 22.5) "5 V maps to one gauge segment"
Assert-True ((Get-ErrorAngleOffset -200.0) -eq -90.0) "negative 200 V maps to the negative scale limit"
Assert-True ((Get-ErrorAngleOffset 500.0) -eq 90.0) "errors above 200 V clamp to the scale limit"

$ack = [System.Text.Encoding]::ASCII.GetBytes("(ACK`r")
$nak = [System.Text.Encoding]::ASCII.GetBytes("(NAK`r")
Assert-True (Test-CorrectionAck $ack) "ACK response is accepted"
Assert-True (-not (Test-CorrectionAck $nak)) "NAK response is rejected"
Assert-True (-not (Test-CorrectionAck ([byte[]]@()))) "empty command response is rejected"

Assert-True (Test-IsNewerVersion "v0.8.2" "0.8.1") "newer patch version is detected"
Assert-True (-not (Test-IsNewerVersion "v0.8.1" "0.8.1")) "equal version is not reported as newer"
Assert-True (-not (Test-IsNewerVersion "v0.7.9" "0.8.1")) "older version is not reported as newer"

Write-Host ""
Write-Host "Logic tests: $($script:Passed) passed, $($script:Failed) failed."
if ($script:Failed -gt 0) { exit 1 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System.Windows.Forms;

public class DoubleBufferedPanel : Panel
{
    public DoubleBufferedPanel()
    {
        this.DoubleBuffered = true;
        this.ResizeRedraw = true;
        this.SetStyle(ControlStyles.AllPaintingInWmPaint |
                      ControlStyles.UserPaint |
                      ControlStyles.OptimizedDoubleBuffer |
                      ControlStyles.ResizeRedraw, true);
        this.UpdateStyles();
    }
}
"@

$Theme = @{
    Window = [System.Drawing.Color]::FromArgb(17, 22, 27)
    Surface = [System.Drawing.Color]::FromArgb(25, 31, 37)
    Panel = [System.Drawing.Color]::FromArgb(31, 38, 45)
    Field = [System.Drawing.Color]::FromArgb(13, 17, 21)
    Border = [System.Drawing.Color]::FromArgb(78, 91, 104)
    Text = [System.Drawing.Color]::FromArgb(226, 235, 244)
    Muted = [System.Drawing.Color]::FromArgb(154, 168, 181)
    Accent = [System.Drawing.Color]::FromArgb(255, 194, 90)
    Good = [System.Drawing.Color]::FromArgb(78, 210, 126)
    Bad = [System.Drawing.Color]::FromArgb(242, 91, 91)
    Info = [System.Drawing.Color]::FromArgb(94, 157, 255)
}

$BaudRate = 2400
$ProbeCommand = "^P003PI"
$ProbeResponseHex = "5E-44-30-30-35-31-37-CA-EC-0D"
$BootLoadCommand = "^S005LON1"
$BootFeedWaitCommand = "^S006FT005"
$GsCommand = "^P003GS"
$IngsCommand = "^P005INGS"
$script:Tolerance = 5.0
$TargetFactor = 1.414
$script:CorrectionDelaySeconds = 4.0
$script:PostCorrectionSampleIntervalSeconds = 1.0
$script:MaxBatchRounds = 30
$script:StableConfirmSamples = 4
$script:StableConfirmMaxAttempts = 3
$script:StableErrorSpanLimit = 0.8
$StableRequiredForCalibration = $true
$BootRetrySeconds = 10.0
$BootReadyMaxError = 25.0
$BootReadyTimeoutSeconds = 240.0
$TrendStartMaxError = 25.0
$ReadSampleMaxRetries = 3
$ProbeMaxAttempts = 3
$ProbeRetrySeconds = 0.8
$ResponseWindowCommands = 6
$ResponseWindowMovementThreshold = 0.5
$ResponseDirectionConfirmCommands = 3
$DirectionTolerance = 1.0
$WorsenTolerance = 1.0
$CorrectionCommandPrefixes = @{
    VDSPP = "BPVA"
    VDSPN = "BNVA"
    VMCUP = "SBPVA"
    VMCUN = "SBNVA"
}

$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$script:AppDataDirectory = Join-Path $localAppData "BUS Voltage Correction"
$script:LogDirectory = Join-Path $script:AppDataDirectory "logs"
if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
    [void](New-Item -ItemType Directory -Path $script:LogDirectory -Force)
}
$script:SessionLogPath = Join-Path $script:LogDirectory ("session_log_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

$script:StopRequested = $false
$script:MonitoringActive = $false
$script:CalibrationActive = $false
$script:SerialOperationActive = $false
$script:SerialLock = New-Object Object
$script:SerialPort = $null
$script:SerialPortName = $null
$script:Samples = New-Object System.Collections.ArrayList
$script:TrendBusReady = $false
$script:Latest = $null
$script:DisplayedErrors = @{}
$script:TargetErrors = @{}
$script:CalibrationSteps = New-Object System.Collections.ArrayList
$script:EventLogLines = New-Object System.Collections.ArrayList
$script:CalibrationLogStartIndex = 0
$script:CalibrationBefore = $null
$script:CalibrationAfter = $null
$script:LastSummaryKey = ""
$script:ManualPending = @{}
$script:ManualQueueBusy = $false
$script:ManualPendingLimit = 20
$script:NextMonitorRead = Get-Date
$script:VisibleLogLines = New-Object System.Collections.ArrayList
$MaxVisibleLogLines = 300
$MaxEventLogLines = 5000
function Write-Log($text) {
    $time = Get-Date -Format "HH:mm:ss"
    $line = "$time - $text"
    try {
        [System.IO.File]::AppendAllText($script:SessionLogPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {
    }
    [void]$script:EventLogLines.Add($line)
    while ($script:EventLogLines.Count -gt $MaxEventLogLines) {
        $script:EventLogLines.RemoveAt(0)
        if ($script:CalibrationLogStartIndex -gt 0) { $script:CalibrationLogStartIndex -= 1 }
    }

    [void]$script:VisibleLogLines.Add($line)
    if ($script:VisibleLogLines.Count -gt $MaxVisibleLogLines) {
        $script:VisibleLogLines.RemoveAt(0)
        $log.Lines = [string[]]$script:VisibleLogLines
    } else {
        $log.AppendText("$line`r`n")
    }
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
}

function Close-SerialConnection {
    $sp = $script:SerialPort
    $script:SerialPort = $null
    $script:SerialPortName = $null
    if ($null -eq $sp) { return }
    try {
        if ($sp.IsOpen) { $sp.Close() }
    } catch {
    } finally {
        try { $sp.Dispose() } catch {}
    }
}

function Get-SerialConnection($portName) {
    if (-not $portName) { throw "No COM port selected." }
    if ($script:SerialPort -and $script:SerialPort.IsOpen -and $script:SerialPortName -eq $portName) {
        return $script:SerialPort
    }

    Close-SerialConnection
    $sp = New-Object System.IO.Ports.SerialPort $portName, $BaudRate, "None", 8, "One"
    $sp.ReadTimeout = 200
    $sp.WriteTimeout = 1000
    try {
        $sp.Open()
    } catch {
        try { $sp.Dispose() } catch {}
        throw
    }
    $script:SerialPort = $sp
    $script:SerialPortName = $portName
    Write-Log "Serial session opened on $portName."
    return $sp
}

function Send-Command($portName, $command, $timeoutMs = 2000) {
    [System.Threading.Monitor]::Enter($script:SerialLock)
    try {
        $script:SerialOperationActive = $true
        $sp = Get-SerialConnection $portName
        $sp.DiscardInBuffer()
        $sp.DiscardOutBuffer()
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($command + "`r`n")
        $sp.Write($bytes, 0, $bytes.Length)
        $buffer = New-Object System.Collections.Generic.List[byte]
        $responseComplete = $false
        $start = Get-Date
        while (((Get-Date) - $start).TotalMilliseconds -lt $timeoutMs) {
            try {
                $b = $sp.ReadByte()
                if ($b -ge 0) {
                    $buffer.Add([byte]$b)
                    if ($b -eq 13) {
                        $responseComplete = $true
                        break
                    }
                }
            } catch [TimeoutException] {
                Start-Sleep -Milliseconds 20
            }
        }
        if ($buffer.Count -eq 0) { throw "No response from $portName for command '$command'." }
        if (-not $responseComplete) { throw "Incomplete response from $portName for command '$command'." }
        return ,$buffer.ToArray()
    } catch {
        Close-SerialConnection
        throw
    } finally {
        $script:SerialOperationActive = $false
        [System.Threading.Monitor]::Exit($script:SerialLock)
    }
}

function Bytes-ToText($bytes) {
    return [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetString($bytes)
}

function Test-InverterPort($portName) {
    for ($attempt = 1; $attempt -le $ProbeMaxAttempts; $attempt++) {
        try {
            $bytes = Send-Command $portName $ProbeCommand
            $hex = [BitConverter]::ToString($bytes)
            Write-Log "Probe $portName attempt $attempt/$ProbeMaxAttempts response: $hex"
            if ($hex.Contains($ProbeResponseHex)) {
                return $true
            }
        } catch {
            Write-Log "Probe $portName attempt $attempt/$ProbeMaxAttempts failed: $($_.Exception.Message)"
        }
        if ($attempt -lt $ProbeMaxAttempts) {
            Wait-WithUi $ProbeRetrySeconds
        }
    }
    Write-Log "Probe $portName failed after $ProbeMaxAttempts attempts."
    return $false
}

function Parse-DeciVolt($fields, $index) {
    if ($index -ge $fields.Count) { throw "missing field index $index" }
    $raw = ($fields[$index].ToCharArray() | Where-Object { "+-0123456789".Contains($_) }) -join ""
    if (-not $raw) { throw "empty field index $index" }
    return [int]$raw / 10.0
}

function Read-SampleOnce($portName) {
    [System.Threading.Monitor]::Enter($script:SerialLock)
    try {
        $gs = Bytes-ToText (Send-Command $portName $GsCommand)
        $ings = Bytes-ToText (Send-Command $portName $IngsCommand)
    } finally {
        [System.Threading.Monitor]::Exit($script:SerialLock)
    }
    $gsFields = $gs.Trim().Split(",")
    $ingsFields = $ings.Trim().Split(",")
    if ($gsFields.Count -le 9) {
        throw "GS response incomplete: expected field 9, got $($gsFields.Count). raw='$($gs.Trim())'"
    }
    if ($ingsFields.Count -le 9) {
        throw "INGS response incomplete: expected field 9, got $($ingsFields.Count). raw='$($ings.Trim())'"
    }
    $vr = Parse-DeciVolt $gsFields 7
    $vs = Parse-DeciVolt $gsFields 8
    $vt = Parse-DeciVolt $gsFields 9
    $target = $TargetFactor * [Math]::Max($vr, [Math]::Max($vs, $vt))
    $sample = [pscustomobject]@{
        Time = Get-Date
        VR = $vr
        VS = $vs
        VT = $vt
        Target = $target
        VDSPP = Parse-DeciVolt $ingsFields 6
        VDSPN = Parse-DeciVolt $ingsFields 7
        VMCUP = Parse-DeciVolt $ingsFields 8
        VMCUN = Parse-DeciVolt $ingsFields 9
    }
    return $sample
}

function Read-Sample($portName) {
    $lastError = $null
    for ($try = 1; $try -le $ReadSampleMaxRetries; $try++) {
        try {
            return Read-SampleOnce $portName
        } catch {
            $lastError = $_.Exception.Message
            Write-Log ("Read sample failed {0}/{1}: {2}" -f $try, $ReadSampleMaxRetries, $lastError)
            Close-SerialConnection
            if ($try -lt $ReadSampleMaxRetries) {
                Wait-WithUi 0.3
            }
        }
    }
    throw "Read sample failed after $ReadSampleMaxRetries retries: $lastError"
}

function Read-SampleSafe($portName, $contextText) {
    try {
        return Read-Sample $portName
    } catch {
        Write-Log ("{0}: failed to read final sample safely: {1}" -f $contextText, $_.Exception.Message)
        return $null
    }
}

function Test-InverterBusReady($sample) {
    if ($null -eq $sample) { return $false }
    $maxError = 0.0
    foreach ($key in @("VDSPP", "VDSPN", "VMCUP", "VMCUN")) {
        $error = [Math]::Abs([double]($sample.$key - $sample.Target))
        if ($error -gt $maxError) { $maxError = $error }
    }
    return ($maxError -le $BootReadyMaxError)
}

function Send-BootCommands($portName) {
    Write-Log "Inverter BUS is not ready. Sending boot commands..."
    try {
        $loadResponse = Send-Command $portName $BootLoadCommand
        Write-Log ("Boot command {0} response: {1}" -f $BootLoadCommand, ([BitConverter]::ToString($loadResponse)))
    } catch {
        Write-Log ("Boot command {0} failed: {1}" -f $BootLoadCommand, $_.Exception.Message)
    }

    try {
        $feedResponse = Send-Command $portName $BootFeedWaitCommand
        Write-Log ("Boot command {0} response: {1}" -f $BootFeedWaitCommand, ([BitConverter]::ToString($feedResponse)))
    } catch {
        Write-Log ("Boot command {0} failed: {1}" -f $BootFeedWaitCommand, $_.Exception.Message)
    }
}

function Ensure-InverterReady($portName) {
    $deadline = (Get-Date).AddSeconds($BootReadyTimeoutSeconds)
    $keys = @("VDSPP", "VDSPN", "VMCUP", "VMCUN")
    $attempt = 0

    while ((Get-Date) -lt $deadline -and -not $script:StopRequested) {
        $attempt += 1
        $sample = $null
        try {
            $sample = Read-Sample $portName
            Update-SampleUi $sample
            $minBus = (@($sample.VDSPP, $sample.VDSPN, $sample.VMCUP, $sample.VMCUN) | Measure-Object -Minimum).Minimum
            $maxBootError = 0.0
            foreach ($key in $keys) {
                $err = [Math]::Abs([double]($sample.$key - $sample.Target))
                if ($err -gt $maxBootError) { $maxBootError = $err }
            }
            Write-Log ("Boot check {0}: min BUS={1:N1}V target={2:N1}V max_error={3:N1}V ready_limit={4:N1}V" -f $attempt, $minBus, $sample.Target, $maxBootError, $BootReadyMaxError)

            if (Test-InverterBusReady $sample) {
                $customerStatus.Text = "BUS voltage is up. Starting independent channel stability tracking..."
                $customerStatus.ForeColor = $Theme.Info
                Write-Log "Inverter startup confirmed. Each BUS channel will now be stabilized independently before correction."
                return $sample
            } else {
                $customerStatus.Text = "Inverter is not started. Sending boot command every 10 seconds..."
                $customerStatus.ForeColor = $Theme.Info
                Send-BootCommands $portName
            }
        } catch {
            $customerStatus.Text = "Waiting for inverter communication. Boot command will retry every 10 seconds..."
            $customerStatus.ForeColor = $Theme.Info
            Write-Log "Boot check communication failed: $($_.Exception.Message)"
            Send-BootCommands $portName
        }

        $next = [Math]::Min($BootRetrySeconds, [Math]::Max(0.0, ($deadline - (Get-Date)).TotalSeconds))
        if ($next -gt 0) { Wait-WithUi $next }
    }

    throw "Inverter did not start within $BootReadyTimeoutSeconds seconds. Check COM connection and confirm only AC Grid is connected."
}

function Invoke-CorrectionCommand($portName, $command, $key, $stepTenths) {
    return Send-Command $portName $command
}

function Update-ManualCountLabels {
    if (-not (Get-Variable -Name manualCountLabels -ErrorAction SilentlyContinue)) { return }
    foreach ($key in @("VDSPP", "VDSPN", "VMCUP", "VMCUN")) {
        $pending = if ($script:ManualPending.ContainsKey($key)) { [int]$script:ManualPending[$key] } else { 0 }
        if ($manualCountLabels.ContainsKey("$key-")) {
            $manualCountLabels["$key-"].Text = if ($pending -lt 0) { "Count: $([Math]::Abs($pending))" } else { "Count: 0" }
        }
        if ($manualCountLabels.ContainsKey("$key+")) {
            $manualCountLabels["$key+"].Text = if ($pending -gt 0) { "Count: $pending" } else { "Count: 0" }
        }
    }
}

function Queue-ManualAdjustment($portName, $key, $direction) {
    if (-not $portName) {
        Write-Log "Please scan and select a COM port first."
        return
    }
    if ($script:CalibrationActive) {
        Write-Log "Manual queue ignored: calibration is running."
        return
    }

    if (-not $script:ManualPending.ContainsKey($key)) {
        $script:ManualPending[$key] = 0
    }
    $pending = [int]$script:ManualPending[$key]
    $nextPending = $pending + [int]$direction
    if ([Math]::Abs($nextPending) -gt $script:ManualPendingLimit) {
        Write-Log ("Manual queue {0}: limit reached. Maximum pending count is {1}." -f $key, $script:ManualPendingLimit)
        return
    }

    $script:ManualPending[$key] = $nextPending
    Update-ManualCountLabels
    $queued = [int]$script:ManualPending[$key]
    Write-Log ("Manual queue {0}: pending={1:+0;-0;0}" -f $key, $queued)

    if ((Get-Variable -Name manualQueueTimer -ErrorAction SilentlyContinue) -and -not $manualQueueTimer.Enabled) {
        $manualQueueTimer.Start()
    }
}

function Process-ManualQueue {
    if ($script:ManualQueueBusy -or $script:CalibrationActive -or $script:SerialOperationActive) { return }
    if (-not (Get-Variable -Name combo -ErrorAction SilentlyContinue)) { return }
    if (-not $combo.SelectedItem) { return }

    $nextKey = $null
    $nextDirection = 0
    foreach ($key in @("VDSPP", "VDSPN", "VMCUP", "VMCUN")) {
        $pending = if ($script:ManualPending.ContainsKey($key)) { [int]$script:ManualPending[$key] } else { 0 }
        if ($pending -ne 0) {
            $nextKey = $key
            $nextDirection = if ($pending -gt 0) { 1 } else { -1 }
            break
        }
    }

    if (-not $nextKey) {
        if ((Get-Variable -Name manualQueueTimer -ErrorAction SilentlyContinue) -and $manualQueueTimer.Enabled) {
            $manualQueueTimer.Stop()
        }
        return
    }

    $script:ManualQueueBusy = $true
    $combo.Enabled = $false
    try {
        $script:ManualPending[$nextKey] = [int]$script:ManualPending[$nextKey] - $nextDirection
        Update-ManualCountLabels
        $ok = Manual-AdjustChannel $combo.SelectedItem $nextKey $nextDirection
        if ($ok) {
            Write-Log ("Manual queue {0}: one step completed. pending={1:+0;-0;0}" -f $nextKey, [int]$script:ManualPending[$nextKey])
        } else {
            $script:ManualPending[$nextKey] = [int]$script:ManualPending[$nextKey] + $nextDirection
            Write-Log ("Manual queue {0}: step failed. Pending count kept for review." -f $nextKey)
            if ((Get-Variable -Name manualQueueTimer -ErrorAction SilentlyContinue) -and $manualQueueTimer.Enabled) {
                $manualQueueTimer.Stop()
            }
        }
        Update-ManualCountLabels
    } finally {
        $script:ManualQueueBusy = $false
        if (-not $script:MonitoringActive -and -not $script:CalibrationActive) {
            $combo.Enabled = $true
        }
    }
}

function Manual-AdjustChannel($portName, $key, $direction) {
    if (-not $portName) {
        Write-Log "Please scan and select a COM port first."
        return $false
    }
    if ($script:CalibrationActive) {
        Write-Log "Manual adjust ignored: calibration is running."
        return $false
    }
    if ($script:SerialOperationActive) {
        Write-Log "Manual adjust ignored: serial communication is busy. Please try again."
        return $false
    }

    $stepTenths = 5
    $stepDisplayVolts = $stepTenths / 10.0
    $prefix = $CorrectionCommandPrefixes[$key]
    $sign = if ($direction -gt 0) { "+" } else { "-" }
    $command = "$prefix$sign{0:00}" -f $stepTenths

    try {
        $wasMonitoring = $script:MonitoringActive
        $status.Text = "Manual"
        Write-Log "Manual adjust $key $sign${stepDisplayVolts}V command: $command"
        $response = Invoke-CorrectionCommand $portName $command $key $stepTenths
        Write-Log ("Manual command response: {0}" -f ([BitConverter]::ToString($response)))
        Wait-WithUi $script:CorrectionDelaySeconds
        $stable = Confirm-StableSample $portName @($key) ("Manual {0} post-correction" -f $key)
        if (-not $stable.Stable) {
            Write-Log "Manual correction did not reach stable readings. Using latest valid sample."
        }
        $sample = if ($stable.Sample) { $stable.Sample } else { Read-SampleSafe $portName "Manual correction fallback" }
        if (-not $sample) {
            $customerStatus.Text = "Manual correction completed, but voltage readback failed."
            $customerStatus.ForeColor = $Theme.Bad
            Write-Log "Manual correction readback failed after retries."
            return $false
        }
        Update-SampleUi $sample
        Write-Log ("Manual result {0}: value={1:N1}V error={2:+0.0;-0.0;0.0}V" -f $key, $sample.$key, ($sample.$key - $sample.Target))
        $customerStatus.Text = "Manual $key $sign${stepDisplayVolts}V completed."
        $customerStatus.ForeColor = $Theme.Good
        return $true
    } catch {
        Write-Log "Manual adjust failed: $($_.Exception.Message)"
        $customerStatus.Text = "Manual adjust failed. Check inverter or COM connection."
        $customerStatus.ForeColor = $Theme.Bad
        return $false
    } finally {
        if ($script:MonitoringActive -or $wasMonitoring) {
            $status.Text = "Running"
        } else {
            $status.Text = "Ready"
        }
    }
}

function Set-Value($name, $value) {
    if (-not $labels.ContainsKey($name)) { return }
    $labels[$name].Text = if ($null -eq $value) { "--" } else { "{0:N1} V" -f $value }
}

function Update-SampleUi($sample) {
    $script:Latest = $sample
    Update-VisualErrorTargets $sample
    foreach ($name in @("VR", "VS", "VT", "Target")) {
        Set-Value $name $sample.$name
    }
    $maxTrendError = 0.0
    foreach ($key in @("VDSPP", "VDSPN", "VMCUP", "VMCUN")) {
        $absError = [Math]::Abs([double]($sample.$key - $sample.Target))
        if ($absError -gt $maxTrendError) { $maxTrendError = $absError }
    }
    $busReadyForTrend = (Test-InverterBusReady $sample) -and ($maxTrendError -le $TrendStartMaxError)
    if ($busReadyForTrend) {
        if (-not $script:TrendBusReady) {
            $script:Samples.Clear()
            $script:TrendBusReady = $true
        }
        [void]$script:Samples.Add($sample)
        while ($script:Samples.Count -gt 120) { $script:Samples.RemoveAt(0) }
    }
    $status.Text = "Running"
    Update-StatusPanels $sample
    $bars.Invalidate()
    $trend.Invalidate()
}

function Update-VisualErrorTargets($sample) {
    if ($null -eq $sample) { return }
    foreach ($key in @("VDSPP", "VDSPN", "VMCUP", "VMCUN")) {
        $targetError = [double]($sample.$key - $sample.Target)
        $script:TargetErrors[$key] = $targetError
        if (-not $script:DisplayedErrors.ContainsKey($key)) {
            $script:DisplayedErrors[$key] = $targetError
        }
    }
    if ((Get-Variable -Name barsAnimationTimer -ErrorAction SilentlyContinue) -and -not $barsAnimationTimer.Enabled) {
        $barsAnimationTimer.Start()
    }
}

function Get-DisplayError($key) {
    if ($script:DisplayedErrors.ContainsKey($key)) {
        return [double]$script:DisplayedErrors[$key]
    }
    if ($script:Latest) {
        return [double]($script:Latest.$key - $script:Latest.Target)
    }
    return 0.0
}

function Update-AnimatedErrors {
    $changed = $false
    foreach ($key in @("VDSPP", "VDSPN", "VMCUP", "VMCUN")) {
        if (-not $script:TargetErrors.ContainsKey($key)) { continue }
        $target = [double]$script:TargetErrors[$key]
        $current = if ($script:DisplayedErrors.ContainsKey($key)) { [double]$script:DisplayedErrors[$key] } else { $target }
        $delta = $target - $current
        if ([Math]::Abs($delta) -lt 0.03) {
            if ([Math]::Abs($delta) -gt 0.0) {
                $script:DisplayedErrors[$key] = $target
                $changed = $true
            }
            continue
        }
        $script:DisplayedErrors[$key] = $current + ($delta * 0.22)
        $changed = $true
    }

    if ($changed) {
        if (Get-Variable -Name bars -ErrorAction SilentlyContinue) { $bars.Invalidate() }
    } elseif ((Get-Variable -Name barsAnimationTimer -ErrorAction SilentlyContinue) -and $barsAnimationTimer.Enabled) {
        $barsAnimationTimer.Stop()
    }
}

function Update-StatusPanels($sample) {
    if ($null -eq $sample) { return }

    $items = @(
        [pscustomobject]@{ Name = "VDSPP"; Group = "DSP"; Error = $sample.VDSPP - $sample.Target },
        [pscustomobject]@{ Name = "VDSPN"; Group = "DSP"; Error = $sample.VDSPN - $sample.Target },
        [pscustomobject]@{ Name = "VMCUP"; Group = "MCU"; Error = $sample.VMCUP - $sample.Target },
        [pscustomobject]@{ Name = "VMCUN"; Group = "MCU"; Error = $sample.VMCUN - $sample.Target }
    )
    $allOk = $true
    foreach ($item in $items) {
        if ([Math]::Abs($item.Error) -gt $script:Tolerance) { $allOk = $false }
    }

    $dspWorst = $items | Where-Object { $_.Group -eq "DSP" } | Sort-Object { [Math]::Abs($_.Error) } -Descending | Select-Object -First 1
    $mcuWorst = $items | Where-Object { $_.Group -eq "MCU" } | Sort-Object { [Math]::Abs($_.Error) } -Descending | Select-Object -First 1
    $overallWorst = $items | Sort-Object { [Math]::Abs($_.Error) } -Descending | Select-Object -First 1

    $customerStatus.ForeColor = if ($allOk) { $Theme.Good } else { $Theme.Bad }
    $customerStatus.Text = if ($allOk) { "BUS voltages are within +/-$($script:Tolerance)V tolerance." } else { "BUS voltage correction may be required." }

    Update-LiveSummary $sample
}

function Set-SummaryDisplay($entries) {
    if (-not (Get-Variable -Name summaryStatus -ErrorAction SilentlyContinue)) { return }

    $summaryKey = (($entries | ForEach-Object { "{0}|{1}" -f $_.Text, $_.Color.ToArgb() }) -join "`n")
    if ($summaryKey -eq $script:LastSummaryKey) { return }
    $script:LastSummaryKey = $summaryKey

    if ($summaryStatus -is [System.Windows.Forms.RichTextBox]) {
        $summaryStatus.SuspendLayout()
        try {
            $summaryStatus.Clear()
            foreach ($entry in $entries) {
                $summaryStatus.SelectionStart = $summaryStatus.TextLength
                $summaryStatus.SelectionLength = 0
                $summaryStatus.SelectionColor = $entry.Color
                $summaryStatus.AppendText($entry.Text + "`r`n")
            }
            $summaryStatus.SelectionStart = 0
            $summaryStatus.SelectionLength = 0
        } finally {
            $summaryStatus.ResumeLayout()
        }
        return
    }

    $summaryStatus.ForeColor = if (($entries | Where-Object { $_.Color -eq $Theme.Bad }).Count -gt 0) { $Theme.Bad } else { $Theme.Good }
    $summaryStatus.Text = (($entries | ForEach-Object { $_.Text }) -join "`r`n")
}

function Wait-WithUi($seconds) {
    $end = (Get-Date).AddSeconds([double]$seconds)
    while ((Get-Date) -lt $end -and -not $script:StopRequested) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}

function Get-FixedCorrectionStepTenths([double]$error) {
    if ([Math]::Abs($error) -le [double]$script:Tolerance) { return 0 }
    return 5
}

function Get-CorrectionPlan($key, $error) {
    if ([Math]::Abs($error) -le $script:Tolerance) { return $null }
    $prefix = $CorrectionCommandPrefixes[$key]
    $stepTenths = Get-FixedCorrectionStepTenths $error
    if ($stepTenths -le 0) { return $null }
    $stepText = "{0:00}" -f $stepTenths
    $command = if ($error -gt 0) { "$prefix-$stepText" } else { "$prefix+$stepText" }
    return [pscustomobject]@{
        Command = $command
        StepTenths = $stepTenths
        StepVolts = $stepTenths / 10.0
    }
}

function Get-ExpectedDirection($error) {
    if ($error -gt 0) { return -1 }
    return 1
}

function Get-ExternalLoadAlertText($key) {
    return @(
        "Calibration stopped: $key did not respond to correction commands.",
        "",
        "Please check the inverter wiring before calibration:",
        "- Remove AC Output load.",
        "- Disconnect PV input.",
        "- Disconnect BAT input.",
        "- Disconnect parallel signal cable.",
        "",
        "Only AC Grid should remain connected during BUS voltage calibration."
    ) -join "`r`n"
}

function Add-CalibrationStep($key, $attempt, $command, $before, $after, $result) {
    $item = [pscustomobject]@{
        Time = Get-Date
        Channel = $key
        Attempt = $attempt
        Command = $command
        BeforeVoltage = if ($before) { $before.$key } else { $null }
        BeforeTarget = if ($before) { $before.Target } else { $null }
        BeforeError = if ($before) { $before.$key - $before.Target } else { $null }
        AfterVoltage = if ($after) { $after.$key } else { $null }
        AfterTarget = if ($after) { $after.Target } else { $null }
        AfterError = if ($after) { $after.$key - $after.Target } else { $null }
        TargetShift = if ($before -and $after) { $after.Target - $before.Target } else { $null }
        Result = $result
    }
    [void]$script:CalibrationSteps.Add($item)
    if ($script:Latest) {
        Update-LiveSummary $script:Latest
    }
}

function Get-CommandStepText($command) {
    if ([string]::IsNullOrWhiteSpace($command)) { return "" }
    if ($command -notmatch '([+-])(\d+)$') { return $command }
    $sign = $matches[1]
    $tenths = [int]$matches[2]
    $volts = $tenths / 10.0
    return "{0}{1:N1}" -f $sign, $volts
}

function Get-ChannelFirstBeforeVoltage($key) {
    $firstStep = $script:CalibrationSteps |
        Where-Object { $_.Channel -eq $key -and -not [string]::IsNullOrWhiteSpace($_.Command) -and $null -ne $_.BeforeVoltage } |
        Select-Object -First 1
    if ($firstStep) { return $firstStep.BeforeVoltage }
    if ($script:CalibrationBefore) { return $script:CalibrationBefore.$key }
    return $null
}

function Get-ChannelStepListText($key) {
    $steps = @(
        $script:CalibrationSteps |
            Where-Object { $_.Channel -eq $key -and -not [string]::IsNullOrWhiteSpace($_.Command) } |
            ForEach-Object { Get-CommandStepText $_.Command }
    ) | Where-Object { $_ }
    if ($steps.Count -gt 0) { return ($steps -join ", ") }
    return "none"
}

function Get-CalibrationSummaryEntries($sample, $resultText) {
    $keys = @("VDSPP", "VDSPN", "VMCUP", "VMCUN")
    $entries = New-Object System.Collections.Generic.List[object]
    $allOk = $true
    foreach ($key in $keys) {
        $beforeVoltage = Get-ChannelFirstBeforeVoltage $key
        $nowVoltage = if ($sample) { $sample.$key } else { $null }
        $nowError = if ($sample) { $sample.$key - $sample.Target } else { $null }
        $ok = if ($null -ne $nowError) { [Math]::Abs($nowError) -le $script:Tolerance } else { $false }
        if (-not $ok) { $allOk = $false }
        $beforeText = if ($null -ne $beforeVoltage) { "{0:N1}V" -f $beforeVoltage } else { "N/A" }
        $nowText = if ($null -ne $nowVoltage) { "{0:N1}V" -f $nowVoltage } else { "N/A" }
        $errorText = if ($null -ne $nowError) { "{0:+0.0;-0.0;0.0}V" -f $nowError } else { "N/A" }
        $stepText = Get-ChannelStepListText $key
        $state = if ($null -eq $nowError) { "N/A" } elseif ($ok) { "OK" } elseif ($nowError -gt $script:Tolerance) { "HIGH" } else { "LOW" }
        $entries.Add([pscustomobject]@{
            Text = ("{0}: Before {1}  Now {2} ({3})  {4}`r`n  Steps: {5}" -f $key, $beforeText, $nowText, $errorText, $state, $stepText)
            Color = if ($ok) { $Theme.Good } else { $Theme.Bad }
        })
    }
    $result = if ($resultText) { $resultText } elseif ($allOk) { "Within tolerance" } else { "Needs correction" }
    $entries.Add([pscustomobject]@{
        Text = "Result: $result"
        Color = if (($result -like "Success*") -or ($result -eq "Within tolerance")) { $Theme.Good } else { $Theme.Bad }
    })
    return $entries
}

function Update-LiveSummary($sample) {
    if (-not (Get-Variable -Name summaryStatus -ErrorAction SilentlyContinue)) { return }
    Set-SummaryDisplay (Get-CalibrationSummaryEntries $sample $null)
}

function Get-CalibrationResultSummaryLines($resultText) {
    $keys = @("VDSPP", "VDSPN", "VMCUP", "VMCUN")
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $keys) {
        $beforeVoltage = Get-ChannelFirstBeforeVoltage $key
        $afterVoltage = if ($script:CalibrationAfter) { $script:CalibrationAfter.$key } else { $null }
        $afterError = if ($script:CalibrationAfter) { $script:CalibrationAfter.$key - $script:CalibrationAfter.Target } else { $null }
        $beforeText = if ($null -ne $beforeVoltage) { "{0:N1}V" -f $beforeVoltage } else { "N/A" }
        $afterText = if ($null -ne $afterVoltage) { "{0:N1}V" -f $afterVoltage } else { "N/A" }
        $errorText = if ($null -ne $afterError) { "{0:+0.0;-0.0;0.0}V" -f $afterError } else { "N/A" }
        $lines.Add(("{0}: before {1}, now {2} ({3}), steps {4}" -f $key, $beforeText, $afterText, $errorText, (Get-ChannelStepListText $key)))
    }
    $lines.Add("Result: $resultText")
    return $lines
}

function Get-CalibrationResultSummaryEntries($resultText) {
    return Get-CalibrationSummaryEntries $script:CalibrationAfter $resultText
}

function Update-CalibrationResultSummary($resultText) {
    if (-not (Get-Variable -Name summaryStatus -ErrorAction SilentlyContinue)) { return }

    Set-SummaryDisplay (Get-CalibrationResultSummaryEntries $resultText)
}

function Get-Error($sample, $key) {
    return $sample.$key - $sample.Target
}

function Confirm-StableSample($portName, $keys, $contextText) {
    $lastSample = $null
    for ($attempt = 1; $attempt -le $script:StableConfirmMaxAttempts; $attempt++) {
        if ($script:StopRequested) { break }

        $samples = New-Object System.Collections.ArrayList
        Write-Log ("{0}: stability check attempt {1}, reading {2} sample(s)..." -f $contextText, $attempt, $script:StableConfirmSamples)
        $readFailed = $false
        for ($i = 1; $i -le $script:StableConfirmSamples; $i++) {
            if ($script:StopRequested) { break }
            try {
                $sample = Read-Sample $portName
            } catch {
                $readFailed = $true
                Write-Log ("{0}: stable sample read failed, restarting stability check. {1}" -f $contextText, $_.Exception.Message)
                break
            }
            Update-SampleUi $sample
            [void]$samples.Add($sample)
            $lastSample = $sample
            $lineParts = New-Object System.Collections.Generic.List[string]
            foreach ($key in $keys) {
                $lineParts.Add(("{0}={1:+0.0;-0.0;0.0}V" -f $key, (Get-Error $sample $key)))
            }
            Write-Log ("{0}: stable sample {1}/{2}: {3}" -f $contextText, $i, $script:StableConfirmSamples, ($lineParts -join " "))
            if ($i -lt $script:StableConfirmSamples) {
                Wait-WithUi $script:PostCorrectionSampleIntervalSeconds
            }
        }

        if ($readFailed) {
            Wait-WithUi $script:PostCorrectionSampleIntervalSeconds
            continue
        }

        if ($samples.Count -eq 0) { continue }

        $maxSpan = 0.0
        foreach ($key in $keys) {
            $errors = @($samples | ForEach-Object { Get-Error $_ $key })
            $minErr = ($errors | Measure-Object -Minimum).Minimum
            $maxErr = ($errors | Measure-Object -Maximum).Maximum
            $span = [double]$maxErr - [double]$minErr
            if ($span -gt $maxSpan) { $maxSpan = $span }
        }

        if ($maxSpan -le $script:StableErrorSpanLimit) {
            Write-Log ("{0}: stable confirmed. max_error_span={1:N1}V" -f $contextText, $maxSpan)
            return [pscustomobject]@{
                Stable = $true
                Sample = $lastSample
                Samples = $samples
                MaxSpan = $maxSpan
            }
        }

        Write-Log ("{0}: not stable yet. max_error_span={1:N1}V limit={2:N1}V" -f $contextText, $maxSpan, $script:StableErrorSpanLimit)
        Wait-WithUi $script:PostCorrectionSampleIntervalSeconds
    }

    Write-Log ("{0}: stability check did not fully settle. Continuing with latest sample." -f $contextText)
    return [pscustomobject]@{
        Stable = $false
        Sample = $lastSample
        Samples = $null
        MaxSpan = $null
    }
}

function Measure-ChannelStability($portName, $keys, $contextText) {
    $samples = New-Object System.Collections.ArrayList
    $lastSample = $null
    Write-Log ("{0}: reading {1} sample(s) for independent channel stability..." -f $contextText, $script:StableConfirmSamples)

    for ($i = 1; $i -le $script:StableConfirmSamples; $i++) {
        if ($script:StopRequested) { break }
        try {
            $sample = Read-Sample $portName
        } catch {
            Write-Log ("{0}: sample {1}/{2} failed: {3}" -f $contextText, $i, $script:StableConfirmSamples, $_.Exception.Message)
            return [pscustomobject]@{ Valid = $false; Sample = $lastSample; Stable = @{}; Spans = @{}; Samples = $samples }
        }
        Update-SampleUi $sample
        [void]$samples.Add($sample)
        $lastSample = $sample
        if ($i -lt $script:StableConfirmSamples) {
            Wait-WithUi $script:PostCorrectionSampleIntervalSeconds
        }
    }

    if ($samples.Count -lt $script:StableConfirmSamples) {
        return [pscustomobject]@{ Valid = $false; Sample = $lastSample; Stable = @{}; Spans = @{}; Samples = $samples }
    }

    $stableByKey = @{}
    $spanByKey = @{}
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($key in $keys) {
        $errors = @($samples | ForEach-Object { Get-Error $_ $key })
        $minErr = ($errors | Measure-Object -Minimum).Minimum
        $maxErr = ($errors | Measure-Object -Maximum).Maximum
        $span = [double]$maxErr - [double]$minErr
        $isStable = ($span -le $script:StableErrorSpanLimit)
        $spanByKey[$key] = $span
        $stableByKey[$key] = $isStable
        $parts.Add(("{0}={1} span={2:N1}V err={3:+0.0;-0.0;0.0}V" -f $key, $(if ($isStable) { "stable" } else { "waiting" }), $span, (Get-Error $lastSample $key)))
    }
    Write-Log ("{0}: {1}" -f $contextText, ($parts -join "; "))
    return [pscustomobject]@{
        Valid = $true
        Sample = $lastSample
        Stable = $stableByKey
        Spans = $spanByKey
        Samples = $samples
    }
}

function Format-SampleLine($sample, $prefix) {
    if ($null -eq $sample) { return "${prefix}: N/A" }
    return ("{0}: Target={1:N1}V VR={2:N1} VS={3:N1} VT={4:N1} VDSPP={5:N1}({6:+0.0;-0.0;0.0}) VDSPN={7:N1}({8:+0.0;-0.0;0.0}) VMCUP={9:N1}({10:+0.0;-0.0;0.0}) VMCUN={11:N1}({12:+0.0;-0.0;0.0})" -f `
        $prefix, $sample.Target, $sample.VR, $sample.VS, $sample.VT, `
        $sample.VDSPP, ($sample.VDSPP - $sample.Target), `
        $sample.VDSPN, ($sample.VDSPN - $sample.Target), `
        $sample.VMCUP, ($sample.VMCUP - $sample.Target), `
        $sample.VMCUN, ($sample.VMCUN - $sample.Target))
}

function Write-CalibrationReport($portName, $statusText) {
    $path = Join-Path $script:LogDirectory ("calibration_report_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("BUS Voltage Correction Report")
    $lines.Add(("Time: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
    $lines.Add("Port: $portName")
    $lines.Add("Result: $statusText")
    $lines.Add("Tolerance: +/-$($script:Tolerance)V")
    $lines.Add("Probe retry: $ProbeMaxAttempts attempt(s), $($ProbeRetrySeconds)s between attempts")
    $lines.Add("Read retry: $ReadSampleMaxRetries attempt(s) for incomplete or empty voltage responses")
    $lines.Add("Correction step: fixed 0.5V command step")
    $lines.Add("Max batch rounds: $script:MaxBatchRounds")
    $lines.Add("Reaction wait: $($script:CorrectionDelaySeconds)s fixed")
    $lines.Add("Startup check: boot commands every $($BootRetrySeconds)s until every BUS error is within +/-$($BootReadyMaxError)V and stable, or timeout $($BootReadyTimeoutSeconds)s")
    $lines.Add("Stability confirm: $($script:StableConfirmSamples) samples, sample interval $($script:PostCorrectionSampleIntervalSeconds)s, max attempts $($script:StableConfirmMaxAttempts), span limit $($script:StableErrorSpanLimit)V")
    $lines.Add("Each BUS channel is stabilized independently before its next correction command.")
    $lines.Add("Success requires two consecutive complete stability windows with all four channels inside tolerance.")
    $lines.Add("No-response guard: evaluate $ResponseWindowCommands consecutive 0.5V commands in the same direction; stop when net movement is below $($ResponseWindowMovementThreshold)V")
    $lines.Add("Direction guard: opposite movement or worsening error must persist across at least $ResponseDirectionConfirmCommands consecutive commands.")
    $lines.Add("")
    $lines.Add((Format-SampleLine $script:CalibrationBefore "Before"))
    $lines.Add((Format-SampleLine $script:CalibrationAfter "After"))
    $lines.Add("")
    $lines.Add("Calibration Summary:")
    foreach ($summaryLine in (Get-CalibrationResultSummaryLines $statusText)) {
        $lines.Add($summaryLine)
    }
    $lines.Add("")
    $lines.Add("Step Log:")
    if ($script:CalibrationSteps.Count -eq 0) {
        $lines.Add("No correction step was required.")
    } else {
        foreach ($step in $script:CalibrationSteps) {
            $before = if ($null -ne $step.BeforeError) { "{0:+0.0;-0.0;0.0}V" -f $step.BeforeError } else { "N/A" }
            $after = if ($null -ne $step.AfterError) { "{0:+0.0;-0.0;0.0}V" -f $step.AfterError } else { "N/A" }
            $targetShift = if ($null -ne $step.TargetShift) { "{0:+0.0;-0.0;0.0}V" -f $step.TargetShift } else { "N/A" }
            $lines.Add(("{0:HH:mm:ss} {1} attempt={2} command={3} before={4:N1}V/{5} after={6:N1}V/{7} target_shift={8} result={9}" -f `
                $step.Time, $step.Channel, $step.Attempt, $step.Command, `
                $step.BeforeVoltage, $before, $step.AfterVoltage, $after, $targetShift, $step.Result))
        }
    }
    $lines.Add("")
    $lines.Add("Event Log:")
    $startIndex = [Math]::Max(0, [int]$script:CalibrationLogStartIndex)
    if ($script:EventLogLines.Count -le $startIndex) {
        $lines.Add("No event log entries were captured for this calibration.")
    } else {
        for ($i = $startIndex; $i -lt $script:EventLogLines.Count; $i++) {
            $lines.Add([string]$script:EventLogLines[$i])
        }
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    Write-Log "Calibration report written: $path"
    return $path
}

function Calibrate-All($portName) {
    $script:StopRequested = $false
    $script:CalibrationSteps.Clear()
    $script:CalibrationLogStartIndex = $script:EventLogLines.Count
    $script:CalibrationBefore = $null
    $script:CalibrationAfter = $null
    $script:Samples.Clear()
    $script:TrendBusReady = $false
    $status.Text = "Calibrating"
    $customerStatus.Text = "Checking inverter startup before BUS voltage calibration..."
    $customerStatus.ForeColor = $Theme.Info
    Write-Log "Starting V0.7 batch calibration on $portName. Max batch rounds: $script:MaxBatchRounds, tolerance=+/-$($script:Tolerance)V, fixed step=0.5V"
    $script:CalibrationBefore = Ensure-InverterReady $portName
    Update-SampleUi $script:CalibrationBefore
    $customerStatus.Text = "Calibrating BUS voltage with 4-channel batch correction..."

    $resultText = "Success: all channels completed"
    $keys = @("VDSPP", "VDSPN", "VMCUP", "VMCUN")
    $responseWindows = @{}
    foreach ($key in $keys) {
        $responseWindows[$key] = New-Object System.Collections.ArrayList
    }

    $awaitingResult = @{}
    $finalVerificationPasses = 0
    $requiredFinalPasses = 2
    $completed = $false
    $lastSample = $script:CalibrationBefore

    for ($round = 1; $round -le $script:MaxBatchRounds; $round++) {
        if ($script:StopRequested) { break }
        $window = Measure-ChannelStability $portName $keys ("Controller cycle {0}" -f $round)
        if (-not $window.Valid -or -not $window.Sample) {
            Write-Log ("Controller cycle {0}: no complete stability window; retrying." -f $round)
            continue
        }

        $current = $window.Sample
        $lastSample = $current
        $fatalResult = $null
        $fatalMessage = $null

        foreach ($key in @($keys)) {
            if (-not $awaitingResult.ContainsKey($key)) { continue }
            if (-not [bool]$window.Stable[$key]) {
                Write-Log ("{0}: waiting for stable readback before evaluating the previous command." -f $key)
                continue
            }

            $pendingResult = $awaitingResult[$key]
            $awaitingResult.Remove($key)
            $item = $pendingResult.Item
            $before = $pendingResult.Before
            $beforeError = [double]$item.Error
            $afterError = Get-Error $current $key
            $errorImprovement = [Math]::Abs($beforeError) - [Math]::Abs($afterError)
            $valueMovement = $current.$key - $before.$key
            $expectedMovement = $valueMovement * $item.ExpectedDirection
            $targetShift = $current.Target - $before.Target

            Write-Log ("{0} stable result: before={1:N1}V after={2:N1}V error={3:+0.0;-0.0;0.0}V improvement={4:+0.0;-0.0;0.0}V movement={5:+0.0;-0.0;0.0}V target_shift={6:+0.0;-0.0;0.0}V" -f $key, $before.$key, $current.$key, $afterError, $errorImprovement, $valueMovement, $targetShift)

            if ([Math]::Abs($afterError) -le $script:Tolerance) {
                $responseWindows[$key].Clear()
                Add-CalibrationStep $key $item.Attempt $item.Command $before $current "Reached tolerance"
                continue
            }

            $history = $responseWindows[$key]
            if ($history.Count -gt 0 -and [double]$history[0].Direction -ne [double]$item.ExpectedDirection) {
                Write-Log ("{0}: correction direction changed; starting a new response window." -f $key)
                $history.Clear()
            }
            [void]$history.Add([pscustomobject]@{
                Direction = [double]$item.ExpectedDirection
                BeforeVoltage = [double]$before.$key
                BeforeError = [double]$beforeError
                AfterVoltage = [double]$current.$key
                AfterError = [double]$afterError
                Command = [string]$item.Command
            })
            while ($history.Count -gt $ResponseWindowCommands) { $history.RemoveAt(0) }

            $baseline = $history[0]
            $windowDirection = [double]$baseline.Direction
            $windowNetMovement = ([double]$current.$key - [double]$baseline.BeforeVoltage) * $windowDirection
            $windowErrorImprovement = [Math]::Abs([double]$baseline.BeforeError) - [Math]::Abs([double]$afterError)
            $windowCommandVolts = $history.Count * 0.5
            Write-Log ("{0} response window: {1}/{2} command(s), requested={3:N1}V, net_expected_movement={4:+0.0;-0.0;0.0}V, net_error_improvement={5:+0.0;-0.0;0.0}V" -f $key, $history.Count, $ResponseWindowCommands, $windowCommandVolts, $windowNetMovement, $windowErrorImprovement)

            if (($history.Count -ge $ResponseDirectionConfirmCommands) -and ($windowNetMovement -lt (-1 * $DirectionTolerance))) {
                $fatalResult = "$key Opposite direction"
                $customerStatus.Text = "$key repeatedly moved in the opposite direction. Stop calibration and check system."
                $customerStatus.ForeColor = $Theme.Bad
                Write-Log "CUSTOMER ALERT: $key showed cumulative opposite movement across multiple commands."
                Add-CalibrationStep $key $item.Attempt $item.Command $before $current "Opposite direction"
                break
            }
            if (($history.Count -ge $ResponseDirectionConfirmCommands) -and ($windowErrorImprovement -lt (-1 * $WorsenTolerance)) -and ($windowNetMovement -lt $ResponseWindowMovementThreshold)) {
                $fatalResult = "$key Worse"
                $customerStatus.Text = "$key error repeatedly became worse. Stop calibration and check system."
                $customerStatus.ForeColor = $Theme.Bad
                Write-Log "CUSTOMER ALERT: $key error became cumulatively worse across multiple commands."
                Add-CalibrationStep $key $item.Attempt $item.Command $before $current "Worse"
                break
            }
            if (($history.Count -ge $ResponseWindowCommands) -and ($windowNetMovement -lt $ResponseWindowMovementThreshold)) {
                $fatalResult = "$key Possible external load"
                $fatalMessage = Get-ExternalLoadAlertText $key
                $customerStatus.Text = "$key did not respond after six corrections. Check wiring: only AC Grid should be connected."
                $customerStatus.ForeColor = $Theme.Bad
                Write-Log ("CUSTOMER ALERT: {0} received {1} consecutive 0.5V commands ({2:N1}V requested), but net movement was only {3:N1}V and error improvement was {4:N1}V." -f $key, $history.Count, $windowCommandVolts, $windowNetMovement, $windowErrorImprovement)
                Add-CalibrationStep $key $item.Attempt $item.Command $before $current "Possible external load"
                break
            }
            Add-CalibrationStep $key $item.Attempt $item.Command $before $current "Continue"
        }

        if ($fatalResult) {
            $resultText = "Stopped: $fatalResult"
            $script:CalibrationAfter = $current
            Update-SampleUi $script:CalibrationAfter
            Update-CalibrationResultSummary $resultText
            $reportPath = Write-CalibrationReport $portName $resultText
            $message = if ($fatalMessage) { "$fatalMessage`r`n`r`nReport: $reportPath" } else { "Calibration stopped.`r`nReport: $reportPath" }
            [System.Windows.Forms.MessageBox]::Show($message, "Calibration Stopped", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $status.Text = "Ready"
            return
        }

        $commandsToSend = New-Object System.Collections.ArrayList
        $allStableAndWithin = ($awaitingResult.Count -eq 0)
        foreach ($key in $keys) {
            if ($awaitingResult.ContainsKey($key)) {
                $allStableAndWithin = $false
                continue
            }
            if (-not [bool]$window.Stable[$key]) {
                $allStableAndWithin = $false
                Write-Log ("{0}: not stable yet; no correction command sent." -f $key)
                continue
            }
            $err = Get-Error $current $key
            if ([Math]::Abs($err) -le $script:Tolerance) {
                $responseWindows[$key].Clear()
                Write-Log ("{0}: stable and within tolerance, error={1:+0.0;-0.0;0.0}V" -f $key, $err)
                continue
            }
            $allStableAndWithin = $false
            $plan = Get-CorrectionPlan $key $err
            [void]$commandsToSend.Add([pscustomobject]@{
                Key = $key
                Error = $err
                Command = $plan.Command
                StepTenths = $plan.StepTenths
                StepVolts = $plan.StepVolts
                ExpectedDirection = Get-ExpectedDirection $err
                Attempt = $round
            })
        }

        if ($allStableAndWithin) {
            $finalVerificationPasses += 1
            $customerStatus.Text = "Final verification $finalVerificationPasses/${requiredFinalPasses}: all channels are stable and within tolerance."
            $customerStatus.ForeColor = $Theme.Good
            Write-Log ("Final verification pass {0}/{1}: all four channels are independently stable and within tolerance." -f $finalVerificationPasses, $requiredFinalPasses)
            if ($finalVerificationPasses -ge $requiredFinalPasses) {
                $completed = $true
                $script:CalibrationAfter = $current
                Update-SampleUi $script:CalibrationAfter
                $customerStatus.Text = "Calibration success: all channels remained stable and within tolerance."
                $customerStatus.ForeColor = $Theme.Good
                Write-Log "V0.7 calibration success after two consecutive final verification windows."
                break
            }
            Write-Log ("Waiting {0:N1}s before the next final verification window." -f $script:PostCorrectionSampleIntervalSeconds)
            Wait-WithUi $script:PostCorrectionSampleIntervalSeconds
            continue
        }
        $finalVerificationPasses = 0

        if ($commandsToSend.Count -gt 0) {
            Write-Log ("========== Controller cycle {0}: correcting {1} stable channel(s) ==========" -f $round, $commandsToSend.Count)
            foreach ($item in $commandsToSend) {
                if ($script:StopRequested) { break }
                Write-Log ("Send {0}: stable error={1:+0.0;-0.0;0.0}V step={2:N1}V command={3}" -f $item.Key, $item.Error, $item.StepVolts, $item.Command)
                $response = Invoke-CorrectionCommand $portName $item.Command $item.Key $item.StepTenths
                Write-Log ("{0} command response: {1}" -f $item.Key, ([BitConverter]::ToString($response)))
                $awaitingResult[$item.Key] = [pscustomobject]@{ Item = $item; Before = $current }
            }
            if (-not $script:StopRequested) {
                Write-Log ("Waiting {0:N1}s minimum reaction time before independent stability checks resume..." -f $script:CorrectionDelaySeconds)
                Wait-WithUi $script:CorrectionDelaySeconds
            }
        }
    }

    if (-not $completed -and -not $script:StopRequested) {
        $resultText = "Stopped: reached maximum controller cycles"
        $customerStatus.Text = "Reached maximum controller cycles. Stop calibration and check system."
        $customerStatus.ForeColor = $Theme.Bad
        Write-Log "CUSTOMER ALERT: reached maximum independent-channel controller cycles."
        $script:CalibrationAfter = $lastSample
    }

    if ($script:StopRequested) {
        $resultText = "Stopped by user"
        $customerStatus.Text = "Calibration stopped by user."
        $customerStatus.ForeColor = $Theme.Bad
        Write-Log "Calibration stopped by user."
        $script:CalibrationAfter = Read-SampleSafe $portName "User stop"
        if ($script:CalibrationAfter) { Update-SampleUi $script:CalibrationAfter }
    } elseif ($null -eq $script:CalibrationAfter) {
        $script:CalibrationAfter = Read-SampleSafe $portName "Calibration finish"
        if ($script:CalibrationAfter) { Update-SampleUi $script:CalibrationAfter }
    }
    Update-CalibrationResultSummary $resultText
    $report = Write-CalibrationReport $portName $resultText
    [System.Windows.Forms.MessageBox]::Show("Calibration report generated:`r`n$report", "Calibration Report", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $status.Text = "Ready"
}

function Draw-Bars($sender, $eventArgs) {
    $g = $eventArgs.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(20, 24, 28))
    $w = $sender.Width
    $h = $sender.Height
    if ($null -eq $script:Latest) {
        $g.DrawString("X CONTACTS standby - no data", $form.Font, [System.Drawing.Brushes]::Gray, $w / 2 - 85, $h / 2 - 8)
        return
    }

    $names = @("VDSPP", "VDSPN", "VMCUP", "VMCUN")
    $colors = @{
        VDSPP = [System.Drawing.Color]::FromArgb(255, 88, 88)
        VDSPN = [System.Drawing.Color]::FromArgb(255, 188, 79)
        VMCUP = [System.Drawing.Color]::FromArgb(74, 144, 255)
        VMCUN = [System.Drawing.Color]::FromArgb(96, 214, 112)
    }

    $gridPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 255, 194, 90)), 1
    $gridPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $outerPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(210, 255, 194, 90)), 2
    $tolerancePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(190, 68, 220, 120)), 2
    $tolerancePen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
    $axisPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(105, 255, 194, 90)), 1
    $thinPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 255, 194, 90)), 1
    $arcPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 255, 194, 90)), 3
    $arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $targetArcPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(210, 68, 220, 120)), 4
    $targetArcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $targetArcPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $fontSmall = New-Object System.Drawing.Font("Segoe UI", 8)
    $fontHeader = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $fontBig = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $fontCenter = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)

    $textSafeMargin = 96
    $centerGap = [int]([Math]::Min(370, [Math]::Max(330, $w * 0.29)))
    $eyeRadius = [int]([Math]::Min(($w - ($textSafeMargin * 2) - $centerGap) / 4, ($h - 204) / 2))
    if ($eyeRadius -lt 82) { $eyeRadius = 82 }
    $eyeY = [int]($h / 2 + 12)
    $eyeGap = $centerGap
    $dspX = [int]($w / 2 - $eyeRadius - $eyeGap / 2)
    $mcuX = [int]($w / 2 + $eyeRadius + $eyeGap / 2)
    $topScaleY = 34
    $bottomScaleY = $h - 33
    $contactRadius = [int]($eyeRadius * 0.72)

    $g.DrawString("DSP", $fontHeader, [System.Drawing.Brushes]::WhiteSmoke, $dspX - 16, 8)
    $g.DrawString("MCU", $fontHeader, [System.Drawing.Brushes]::WhiteSmoke, $mcuX - 18, 8)
    $g.DrawString("P", $fontHeader, [System.Drawing.Brushes]::WhiteSmoke, 10, $eyeY - [int]($eyeRadius * 0.55))
    $g.DrawString("N", $fontHeader, [System.Drawing.Brushes]::WhiteSmoke, 10, $eyeY + [int]($eyeRadius * 0.55))

    $tickStart = $dspX - $eyeRadius
    $tickEnd = $mcuX + $eyeRadius
    $g.DrawLine($axisPen, $tickStart, $topScaleY, $tickEnd, $topScaleY)
    $g.DrawLine($axisPen, $tickStart, $bottomScaleY, $tickEnd, $bottomScaleY)
    $scaleValues = @(-200, -50, -20, -5, 0, 5, 20, 50, 200)
    for ($i = 0; $i -lt $scaleValues.Count; $i++) {
        $xTick = [int]($tickStart + (($tickEnd - $tickStart) * $i / ($scaleValues.Count - 1)))
        $tickErr = [double]$scaleValues[$i]
        $tickMajor = ($i -eq 0 -or $i -eq 4 -or $i -eq 8)
        $tickLen = if ($tickMajor) { 9 } else { 6 }
        $g.DrawLine($axisPen, $xTick, $topScaleY, $xTick, $topScaleY + $tickLen)
        $g.DrawLine($axisPen, $xTick, $bottomScaleY, $xTick, $bottomScaleY - $tickLen)
        $label = if ($tickErr -eq 0) { "0V" } else { "{0:+0;-0}V" -f $tickErr }
        $labelOffset = if ([Math]::Abs($tickErr) -ge 100) { 20 } elseif ([Math]::Abs($tickErr) -ge 10) { 17 } else { 14 }
        $g.DrawString($label, $fontSmall, [System.Drawing.Brushes]::Silver, $xTick - $labelOffset, $topScaleY - 18)
        $g.DrawString($label, $fontSmall, [System.Drawing.Brushes]::Silver, $xTick - $labelOffset, $bottomScaleY + 6)
    }

    $eyes = @(
        @{ Title = "DSP"; X = $dspX; P = "VDSPP"; N = "VDSPN"; SplitA = 135.0; SplitB = 315.0; PTarget = 45.0; NTarget = 225.0 },
        @{ Title = "MCU"; X = $mcuX; P = "VMCUP"; N = "VMCUN"; SplitA = 45.0; SplitB = 225.0; PTarget = 135.0; NTarget = 315.0 }
    )
    foreach ($eye in $eyes) {
        $eyeX = [int]$eye.X
        $pairErrors = @(
            [Math]::Abs($script:Latest.($eye.P) - $script:Latest.Target),
            [Math]::Abs($script:Latest.($eye.N) - $script:Latest.Target)
        )
        $splitA = Get-AnglePoint $eyeX $eyeY $eyeRadius ([double]$eye.SplitA)
        $splitB = Get-AnglePoint $eyeX $eyeY $eyeRadius ([double]$eye.SplitB)
        $g.DrawLine($thinPen, $splitA.X, $splitA.Y, $splitB.X, $splitB.Y)

        $scaleFill = [System.Drawing.Color]::FromArgb(120, 188, 119, 35)
        $scaleEdge = [System.Drawing.Color]::FromArgb(235, 255, 198, 83)
        if ($eye.Title -eq "MCU") {
            Draw-ContactScale $g $eyeX $eyeY $eyeRadius 315.0 495.0 8 $scaleFill $scaleEdge $true
            Draw-ContactScale $g $eyeX $eyeY $eyeRadius 135.0 315.0 8 $scaleFill $scaleEdge $true
        } else {
            Draw-ContactScale $g $eyeX $eyeY $eyeRadius 45.0 225.0 8 $scaleFill $scaleEdge $true
            Draw-ContactScale $g $eyeX $eyeY $eyeRadius 225.0 405.0 8 $scaleFill $scaleEdge $true
        }

        $toleranceSpan = [Math]::Abs((Get-ErrorAngleOffset ([double]$script:Tolerance)))
        $targetFill = [System.Drawing.Color]::FromArgb(230, 54, 205, 104)
        $targetEdge = [System.Drawing.Color]::FromArgb(255, 120, 255, 158)
        Draw-ContactToleranceSegment $g $eyeX $eyeY $eyeRadius ([double]$eye.PTarget) ([double]$eye.PTarget + $toleranceSpan) $targetFill $targetEdge
        Draw-ContactToleranceSegment $g $eyeX $eyeY $eyeRadius ([double]$eye.PTarget) ([double]$eye.PTarget - $toleranceSpan) $targetFill $targetEdge
        Draw-ContactToleranceSegment $g $eyeX $eyeY $eyeRadius ([double]$eye.NTarget) ([double]$eye.NTarget + $toleranceSpan) $targetFill $targetEdge
        Draw-ContactToleranceSegment $g $eyeX $eyeY $eyeRadius ([double]$eye.NTarget) ([double]$eye.NTarget - $toleranceSpan) $targetFill $targetEdge

        $g.DrawEllipse($gridPen, $eyeX - [int]($eyeRadius * 0.68), $eyeY - [int]($eyeRadius * 0.68), [int]($eyeRadius * 1.36), [int]($eyeRadius * 1.36))
        $pError = Get-DisplayError $eye.P
        $nError = Get-DisplayError $eye.N
        $bubbleRange = [Math]::Max(0.1, [double]$script:Tolerance)
        $bubbleToleranceRadius = [int]($eyeRadius * 0.28)
        $bubbleSize = [int]($eyeRadius * 0.13)
        $bubbleTravel = ($bubbleToleranceRadius - $bubbleSize) / [Math]::Sqrt(2.0)
        $bubbleRawX = [Math]::Max(-1.65, [Math]::Min(1.65, $pError / $bubbleRange)) * $bubbleTravel
        $bubbleRawY = [Math]::Max(-1.65, [Math]::Min(1.65, $nError / $bubbleRange)) * $bubbleTravel
        $bubbleRotation = [Math]::PI / 4.0
        $bubbleRotatedX = ($bubbleRawX * [Math]::Cos($bubbleRotation)) - ($bubbleRawY * [Math]::Sin($bubbleRotation))
        $bubbleRotatedY = ($bubbleRawX * [Math]::Sin($bubbleRotation)) + ($bubbleRawY * [Math]::Cos($bubbleRotation))
        $bubbleX = $eyeX + [int]$bubbleRotatedX
        $bubbleY = $eyeY + [int]$bubbleRotatedY
        $bubbleDistance = [Math]::Sqrt([Math]::Pow($bubbleX - $eyeX, 2) + [Math]::Pow($bubbleY - $eyeY, 2))
        $bubbleOk = ($bubbleDistance + $bubbleSize) -le $bubbleToleranceRadius
        $bubbleCircleColor = if ($bubbleOk) { [System.Drawing.Color]::FromArgb(190, 68, 220, 120) } else { [System.Drawing.Color]::FromArgb(220, 235, 64, 64) }
        $bubbleCirclePen = New-Object System.Drawing.Pen $bubbleCircleColor, 2
        $bubbleCirclePen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $bubbleBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(210, 65, 75, 210))
        $g.DrawEllipse($bubbleCirclePen, $eyeX - $bubbleToleranceRadius, $eyeY - $bubbleToleranceRadius, $bubbleToleranceRadius * 2, $bubbleToleranceRadius * 2)
        $g.FillEllipse($bubbleBrush, $bubbleX - $bubbleSize, $bubbleY - $bubbleSize, $bubbleSize * 2, $bubbleSize * 2)
        $g.DrawString(("Target`r`n{0:N1} V" -f $script:Latest.Target), $fontCenter, [System.Drawing.Brushes]::WhiteSmoke, $eyeX - 38, $eyeY - 31)

        foreach ($slot in @(
            @{ Key = $eye.P; Label = "P"; TargetAngle = [double]$eye.PTarget },
            @{ Key = $eye.N; Label = "N"; TargetAngle = [double]$eye.NTarget }
        )) {
            $name = $slot.Key
            $err = Get-DisplayError $name
            $actualErr = $script:Latest.$name - $script:Latest.Target
            $absErr = [Math]::Abs($err)
            $angleOffset = Get-ErrorAngleOffset $err
            $currentAngle = [double]$slot.TargetAngle - $angleOffset
            $targetPoint = Get-BracketScalePointF $eyeX $eyeY $contactRadius ([double]$slot.TargetAngle)
            $currentPoint = Get-BracketScalePointF $eyeX $eyeY $contactRadius $currentAngle
            $color = if ($absErr -le $script:Tolerance) { [System.Drawing.Color]::FromArgb(92, 230, 124) } elseif ($absErr -le ($script:Tolerance * 2.0)) { [System.Drawing.Color]::FromArgb(255, 194, 90) } else { [System.Drawing.Color]::FromArgb(255, 91, 91) }
            $linePen = New-Object System.Drawing.Pen $colors[$name], 2
            $linePen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor
            $labelBrush = New-Object System.Drawing.SolidBrush $colors[$name]
            $g.DrawLine($gridPen, $eyeX, $eyeY, $targetPoint.X, $targetPoint.Y)
            $g.DrawLine($linePen, $eyeX, $eyeY, $currentPoint.X, $currentPoint.Y)
            $g.DrawString($slot.Label, $fontHeader, $labelBrush, $currentPoint.X + 8, $currentPoint.Y - 10)
            $directionText = if ($actualErr -gt $script:Tolerance) { "HIGH" } elseif ($actualErr -lt (-1.0 * $script:Tolerance)) { "LOW" } else { "OK" }
            $labelW = 118
            $shapeHalfW = [int]($eyeRadius * 1.18)
            $shapeHalfH = [int]($eyeRadius * 0.92)
            $labelTopY = [Math]::Max(64, $eyeY - $shapeHalfH - 64)
            $labelBottomY = [Math]::Min($h - 104, $eyeY + $shapeHalfH + 18)
            $centerLabelGap = 58
            if ($eye.Title -eq "DSP" -and $slot.Label -eq "P") {
                $labelX = [int]($w / 2 - $labelW - $centerLabelGap)
                $labelY = $labelTopY
            } elseif ($eye.Title -eq "DSP") {
                $labelX = 18
                $labelY = $labelBottomY
            } elseif ($slot.Label -eq "P") {
                $labelX = [int]($w / 2 + $centerLabelGap)
                $labelY = $labelTopY
            } else {
                $labelX = [int]($w - $labelW - 20)
                $labelY = $labelBottomY
            }
            $labelX = [Math]::Max(16, [Math]::Min($w - $labelW - 16, $labelX))
            $labelY = [Math]::Max(48, [Math]::Min($h - 78, $labelY))
            $g.DrawString($name, $fontBig, $labelBrush, $labelX, $labelY)
            $g.DrawString(("{0:N1} V" -f $script:Latest.$name), $fontSmall, [System.Drawing.Brushes]::WhiteSmoke, $labelX, $labelY + 24)
            $g.DrawString(("{0} {1:+0.0;-0.0;0.0} V" -f $directionText, $actualErr), $fontSmall, $(if ([Math]::Abs($actualErr) -le $script:Tolerance) { [System.Drawing.Brushes]::LightGreen } else { [System.Drawing.Brushes]::MistyRose }), $labelX, $labelY + 41)
        }
    }

    $g.DrawString(("Outer ring: tolerance +/-{0:N1} V" -f $script:Tolerance), $fontSmall, [System.Drawing.Brushes]::LightGreen, 16, $h - 17)
    $g.DrawString("Inner ring: current error", $fontSmall, [System.Drawing.Brushes]::WhiteSmoke, 185, $h - 17)
    $g.DrawString("Nonlinear scale to +/-200 V", $fontSmall, [System.Drawing.Brushes]::Silver, $w - 158, $h - 17)
}

function Get-AnglePoint([int]$cx, [int]$cy, [int]$radius, [double]$degrees) {
    $radians = $degrees * [Math]::PI / 180.0
    return [System.Drawing.Point]::new(
        [int]($cx + [Math]::Cos($radians) * $radius),
        [int]($cy - [Math]::Sin($radians) * $radius)
    )
}

function Get-AnglePointF([int]$cx, [int]$cy, [double]$radius, [double]$degrees) {
    $radians = $degrees * [Math]::PI / 180.0
    return [System.Drawing.PointF]::new(
        [single]($cx + [Math]::Cos($radians) * $radius),
        [single]($cy - [Math]::Sin($radians) * $radius)
    )
}

function Get-BracketScalePointF([int]$cx, [int]$cy, [double]$radius, [double]$degrees) {
    $radians = $degrees * [Math]::PI / 180.0
    $cos = [Math]::Cos($radians)
    $sin = [Math]::Sin($radians)
    $maxAxis = [Math]::Max([Math]::Abs($cos), [Math]::Abs($sin))
    if ($maxAxis -lt 0.001) { $maxAxis = 1.0 }

    $circleX = $cos * $radius
    $circleY = $sin * $radius
    $squareX = ($cos / $maxAxis) * $radius
    $squareY = ($sin / $maxAxis) * $radius
    $squareBlend = 0.62

    $wideScale = 1.18
    $flatScale = 0.92
    return [System.Drawing.PointF]::new(
        [single]($cx + ((($circleX * (1.0 - $squareBlend)) + ($squareX * $squareBlend)) * $wideScale)),
        [single]($cy - ((($circleY * (1.0 - $squareBlend)) + ($squareY * $squareBlend)) * $flatScale))
    )
}

function Get-ErrorAngleOffset([double]$error) {
    $sign = if ($error -ge 0) { 1.0 } else { -1.0 }
    $absError = [Math]::Abs($error)

    if ($absError -le 5.0) {
        $offset = 22.5 * ($absError / 5.0)
    } elseif ($absError -le 20.0) {
        $offset = 22.5 + 22.5 * (($absError - 5.0) / 15.0)
    } elseif ($absError -le 50.0) {
        $offset = 45.0 + 22.5 * (($absError - 20.0) / 30.0)
    } elseif ($absError -le 200.0) {
        $offset = 67.5 + 22.5 * (($absError - 50.0) / 150.0)
    } else {
        $offset = 90.0
    }

    return $sign * $offset
}

function Draw-SegmentedArc($g, $pen, [int]$cx, [int]$cy, [int]$radius, [double]$startDeg, [double]$endDeg, [int]$segments) {
    for ($i = 0; $i -lt $segments; $i++) {
        $a = $startDeg + ($endDeg - $startDeg) * (($i + 0.12) / $segments)
        $b = $startDeg + ($endDeg - $startDeg) * (($i + 0.78) / $segments)
        $p1 = Get-AnglePoint $cx $cy $radius $a
        $p2 = Get-AnglePoint $cx $cy $radius $b
        $g.DrawLine($pen, $p1.X, $p1.Y, $p2.X, $p2.Y)
    }
}

function Draw-ContactScale($g, [int]$cx, [int]$cy, [int]$radius, [double]$startDeg, [double]$endDeg, [int]$segments, [System.Drawing.Color]$fillColor, [System.Drawing.Color]$edgeColor, [bool]$glow) {
    $outerRadius = [double]$radius
    $innerRadius = [double]$radius * 0.79
    $span = $endDeg - $startDeg
    if ([Math]::Abs($span) -lt 0.1) { return }

    for ($i = 0; $i -lt $segments; $i++) {
        $gapA = if ($glow) { 0.07 } else { 0.0 }
        $gapB = if ($glow) { 0.90 } else { 1.0 }
        $a = $startDeg + $span * (($i + $gapA) / $segments)
        $b = $startDeg + $span * (($i + $gapB) / $segments)
        $mid = ($a + $b) / 2.0
        $longSegment = ($segments -le 3)
        if (-not $longSegment) {
            if ($i -eq 0 -or $i -eq ($segments - 1)) {
                $innerRadius = [double]$radius * 0.75
            } elseif ($i % 3 -eq 1) {
                $innerRadius = [double]$radius * 0.81
            } else {
                $innerRadius = [double]$radius * 0.78
            }
        }

        $outerA = Get-BracketScalePointF $cx $cy $outerRadius $a
        $outerB = Get-BracketScalePointF $cx $cy $outerRadius $b
        $innerA = Get-BracketScalePointF $cx $cy $innerRadius ($a + (($mid - $a) * 0.10))
        $innerB = Get-BracketScalePointF $cx $cy $innerRadius ($b - (($b - $mid) * 0.10))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $points = [System.Drawing.PointF[]]@($outerA, $outerB, $innerB, $innerA)
        $path.AddPolygon($points)

        if ($glow) {
            $glowPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(55, $edgeColor.R, $edgeColor.G, $edgeColor.B)), 7
            $glowPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $g.DrawPath($glowPen, $path)
            $glowPen.Dispose()
        }

        $brush = New-Object System.Drawing.SolidBrush $fillColor
        $edgePen = New-Object System.Drawing.Pen $edgeColor, 1.6
        $edgePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $g.FillPath($brush, $path)
        $g.DrawPath($edgePen, $path)
        $brush.Dispose()
        $edgePen.Dispose()
        $path.Dispose()
    }
}

function Draw-ContactToleranceSegment($g, [int]$cx, [int]$cy, [int]$radius, [double]$startDeg, [double]$endDeg, [System.Drawing.Color]$fillColor, [System.Drawing.Color]$edgeColor) {
    $span = $endDeg - $startDeg
    if ([Math]::Abs($span) -lt 0.1) { return }

    $segmentUnit = 22.5
    $gapA = [Math]::Min(1.6, [Math]::Abs($span) * 0.16)
    $gapB = [Math]::Min(2.2, [Math]::Abs($span) * 0.16)
    $a = $startDeg + ([Math]::Sign($span) * $gapA)
    $b = $endDeg - ([Math]::Sign($span) * $gapB)
    if (($span -gt 0 -and $b -le $a) -or ($span -lt 0 -and $b -ge $a)) { return }

    $outerRadius = [double]$radius
    $innerRadius = [double]$radius * 0.75
    $mid = ($a + $b) / 2.0
    $innerA = Get-BracketScalePointF $cx $cy $innerRadius ($a + (($mid - $a) * 0.10))
    $innerB = Get-BracketScalePointF $cx $cy $innerRadius ($b - (($b - $mid) * 0.10))
    $outerA = Get-BracketScalePointF $cx $cy $outerRadius $a
    $outerB = Get-BracketScalePointF $cx $cy $outerRadius $b

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $points = [System.Drawing.PointF[]]@($outerA, $outerB, $innerB, $innerA)
    $path.AddPolygon($points)

    $brush = New-Object System.Drawing.SolidBrush $fillColor
    $edgePen = New-Object System.Drawing.Pen $edgeColor, 1.5
    $edgePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.FillPath($brush, $path)
    $g.DrawPath($edgePen, $path)

    $brush.Dispose()
    $edgePen.Dispose()
    $path.Dispose()
}

function Draw-Trend($sender, $eventArgs) {
    $g = $eventArgs.Graphics
    $g.Clear($Theme.Field)
    $w = $sender.Width
    $h = $sender.Height
    if ($script:Samples.Count -lt 2) {
        $g.DrawString("Trend will appear after 2 samples", $form.Font, (New-Object System.Drawing.SolidBrush $Theme.Muted), $w / 2 - 90, $h / 2 - 8)
        return
    }
    $names = @("VDSPP", "VDSPN", "VMCUP", "VMCUN")
    $colors = @{
        VDSPP = $Theme.Bad
        VDSPN = [System.Drawing.Color]::ForestGreen
        VMCUP = $Theme.Info
        VMCUN = [System.Drawing.Color]::Purple
    }
    $errors = @()
    foreach ($s in $script:Samples) {
        foreach ($name in $names) {
            $errors += ($s.$name - $s.Target)
        }
    }
    $maxAbs = [Math]::Max(5.0, [Math]::Ceiling((($errors | ForEach-Object { [Math]::Abs($_) }) | Measure-Object -Maximum).Maximum))
    $tickStep = if ($maxAbs -le 10) { 5 } elseif ($maxAbs -le 25) { 10 } else { 20 }
    $maxAbs = [Math]::Ceiling($maxAbs / $tickStep) * $tickStep
    $min = -1 * $maxAbs
    $max = $maxAbs
    $left = 58; $right = $w - 112; $top = 18; $bottom = $h - 34
    $mid = $bottom - ($bottom - $top) * (0 - $min) / ($max - $min)

    $borderPen = New-Object System.Drawing.Pen $Theme.Border, 1
    $g.DrawRectangle($borderPen, $left, $top, $right - $left, $bottom - $top)
    $latestTarget = $script:Samples[$script:Samples.Count - 1].Target
    $g.DrawString("BUS Error vs Target (V)", $form.Font, (New-Object System.Drawing.SolidBrush $Theme.Muted), $left, 2)

    for ($tick = -1 * $maxAbs; $tick -le $maxAbs; $tick += $tickStep) {
        $yTick = $bottom - ($bottom - $top) * ($tick - $min) / ($max - $min)
        $penTick = if ($tick -eq 0) { New-Object System.Drawing.Pen ($Theme.Text), 2 } else { New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(48, 58, 67)), 1 }
        $g.DrawLine($penTick, $left, [int]$yTick, $right, [int]$yTick)
        $label = if ($tick -eq 0) { "0 V error" } else { "{0:+0;-0} V" -f $tick }
        $g.DrawString($label, $form.Font, (New-Object System.Drawing.SolidBrush $Theme.Muted), 4, [int]$yTick - 8)
    }

    foreach ($name in $names) {
        $pen = New-Object System.Drawing.Pen $colors[$name], 2
        $last = $null
        for ($i = 0; $i -lt $script:Samples.Count; $i++) {
            $x = $left + ($right - $left) * $i / [Math]::Max(1, $script:Samples.Count - 1)
            $err = $script:Samples[$i].$name - $script:Samples[$i].Target
            $y = $bottom - ($bottom - $top) * ($err - $min) / ($max - $min)
            if ($null -ne $last) { $g.DrawLine($pen, $last.X, $last.Y, [int]$x, [int]$y) }
            $last = [System.Drawing.Point]::new([int]$x, [int]$y)
        }
        $g.DrawString($name, $form.Font, (New-Object System.Drawing.SolidBrush $colors[$name]), $right + 8, $top + 18 * [Array]::IndexOf($names, $name))
    }

    $g.DrawString(("Target {0:N1} V" -f $latestTarget), $form.Font, (New-Object System.Drawing.SolidBrush $Theme.Text), $right + 8, [int]$mid - 9)
}

function Apply-ThemeRecursive($control) {
    if ($control -is [System.Windows.Forms.Form]) {
        $control.BackColor = $Theme.Window
        $control.ForeColor = $Theme.Text
    } elseif ($control -is [System.Windows.Forms.GroupBox]) {
        $control.BackColor = $Theme.Surface
        $control.ForeColor = $Theme.Text
    } elseif ($control -is [System.Windows.Forms.Panel]) {
        $control.BackColor = $Theme.Window
        $control.ForeColor = $Theme.Text
    } elseif ($control -is [System.Windows.Forms.Button]) {
        $control.BackColor = $Theme.Panel
        $control.ForeColor = $Theme.Text
        $control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $control.FlatAppearance.BorderColor = $Theme.Border
        $control.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(43, 53, 62)
        $control.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(57, 70, 81)
    } elseif ($control -is [System.Windows.Forms.TextBox]) {
        $control.BackColor = $Theme.Field
        $control.ForeColor = $Theme.Text
        $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    } elseif ($control -is [System.Windows.Forms.ComboBox] -or $control -is [System.Windows.Forms.NumericUpDown]) {
        $control.BackColor = $Theme.Field
        $control.ForeColor = $Theme.Text
    } elseif ($control -is [System.Windows.Forms.CheckBox]) {
        $control.BackColor = $Theme.Window
        $control.ForeColor = $Theme.Text
    } elseif ($control -is [System.Windows.Forms.Label]) {
        $control.BackColor = [System.Drawing.Color]::Transparent
        $control.ForeColor = $Theme.Text
    }

    foreach ($child in $control.Controls) {
        Apply-ThemeRecursive $child
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "BUS Voltage Correction V0.7 - Batch Correction Test"
$form.Size = New-Object System.Drawing.Size(1420, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1240, 820)
$form.StartPosition = "CenterScreen"
$form.ShowInTaskbar = $true
$form.TopMost = $true

$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"
$top.Height = 76
$form.Controls.Add($top)

$comLabel = New-Object System.Windows.Forms.Label
$comLabel.Text = "COM"
$comLabel.Location = New-Object System.Drawing.Point(12, 15)
$comLabel.AutoSize = $true
$top.Controls.Add($comLabel)

$combo = New-Object System.Windows.Forms.ComboBox
$combo.Location = New-Object System.Drawing.Point(55, 10)
$combo.Width = 135
$top.Controls.Add($combo)

$scanButton = New-Object System.Windows.Forms.Button
$scanButton.Text = "Scan"
$scanButton.Location = New-Object System.Drawing.Point(205, 9)
$scanButton.Width = 95
$top.Controls.Add($scanButton)

$monitorButton = New-Object System.Windows.Forms.Button
$monitorButton.Text = "Monitor"
$monitorButton.Location = New-Object System.Drawing.Point(315, 9)
$monitorButton.Width = 105
$top.Controls.Add($monitorButton)

$calibrateButton = New-Object System.Windows.Forms.Button
$calibrateButton.Text = "Calibrate"
$calibrateButton.Location = New-Object System.Drawing.Point(435, 9)
$calibrateButton.Width = 105
$top.Controls.Add($calibrateButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "Stop"
$stopButton.Location = New-Object System.Drawing.Point(555, 9)
$stopButton.Width = 95
$top.Controls.Add($stopButton)

$openLogsButton = New-Object System.Windows.Forms.Button
$openLogsButton.Text = "Open Logs"
$openLogsButton.Location = New-Object System.Drawing.Point(665, 9)
$openLogsButton.Width = 105
$top.Controls.Add($openLogsButton)

$intervalLabel = New-Object System.Windows.Forms.Label
$intervalLabel.Text = "Interval (s)"
$intervalLabel.Location = New-Object System.Drawing.Point(670, 8)
$intervalLabel.AutoSize = $true
$top.Controls.Add($intervalLabel)

$intervalBox = New-Object System.Windows.Forms.NumericUpDown
$intervalBox.Location = New-Object System.Drawing.Point(670, 32)
$intervalBox.Width = 105
$intervalBox.DecimalPlaces = 1
$intervalBox.Minimum = 0.5
$intervalBox.Maximum = 100000
$intervalBox.Increment = 0.5
$intervalBox.Value = 2.0
$top.Controls.Add($intervalBox)

$toleranceLabel = New-Object System.Windows.Forms.Label
$toleranceLabel.Text = "Tolerance (V, 1-5)"
$toleranceLabel.Location = New-Object System.Drawing.Point(680, 8)
$toleranceLabel.AutoSize = $true
$top.Controls.Add($toleranceLabel)

$toleranceBox = New-Object System.Windows.Forms.NumericUpDown
$toleranceBox.Location = New-Object System.Drawing.Point(680, 32)
$toleranceBox.Width = 120
$toleranceBox.DecimalPlaces = 1
$toleranceBox.Minimum = 1.0
$toleranceBox.Maximum = 5.0
$toleranceBox.Increment = 0.5
$toleranceBox.Value = 5.0
$top.Controls.Add($toleranceBox)

$stepLabel = New-Object System.Windows.Forms.Label
$stepLabel.Text = "Stable span (V)"
$stepLabel.Location = New-Object System.Drawing.Point(1135, 8)
$stepLabel.Width = 190
$top.Controls.Add($stepLabel)

$stepBox = New-Object System.Windows.Forms.NumericUpDown
$stepBox.Location = New-Object System.Drawing.Point(1135, 32)
$stepBox.Width = 135
$stepBox.DecimalPlaces = 1
$stepBox.Minimum = 0.1
$stepBox.Maximum = 100000
$stepBox.Increment = 0.1
$stepBox.Value = 0.5
$top.Controls.Add($stepBox)

$status = New-Object System.Windows.Forms.Label
$status.Text = "Ready"
$status.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(825, 29)
$top.Controls.Add($status)

$observeLabel = New-Object System.Windows.Forms.Label
$observeLabel.Text = "Observe"
$observeLabel.Location = New-Object System.Drawing.Point(915, 66)
$observeLabel.AutoSize = $true
$top.Controls.Add($observeLabel)

$observeBox = New-Object System.Windows.Forms.NumericUpDown
$observeBox.Location = New-Object System.Drawing.Point(1085, 62)
$observeBox.Width = 95
$observeBox.DecimalPlaces = 1
$observeBox.Minimum = 0.5
$observeBox.Maximum = 100000
$observeBox.Increment = 0.5
$observeBox.Value = 8.0
$top.Controls.Add($observeBox)

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Location = New-Object System.Drawing.Point(10, 98)
$leftPanel.Size = New-Object System.Drawing.Size(955, 785)
$form.Controls.Add($leftPanel)

$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Location = New-Object System.Drawing.Point(975, 98)
$rightPanel.Size = New-Object System.Drawing.Size(455, 785)
$form.Controls.Add($rightPanel)

$settingsGroup = New-Object System.Windows.Forms.GroupBox
$settingsGroup.Text = "Settings"
$settingsGroup.Location = New-Object System.Drawing.Point(5, 90)
$settingsGroup.Size = New-Object System.Drawing.Size(445, 126)
$rightPanel.Controls.Add($settingsGroup)

$settingsTips = New-Object System.Windows.Forms.ToolTip
$settingsTips.AutoPopDelay = 12000
$settingsTips.InitialDelay = 400
$settingsTips.ReshowDelay = 100

$intervalLabel.Location = New-Object System.Drawing.Point(12, 22)
$intervalBox.Location = New-Object System.Drawing.Point(12, 46)
$intervalLabel.Width = 95
$intervalBox.Width = 78
$settingsGroup.Controls.Add($intervalLabel)
$settingsGroup.Controls.Add($intervalBox)

$toleranceLabel.Location = New-Object System.Drawing.Point(116, 22)
$toleranceLabel.Text = "Tolerance (V)"
$toleranceLabel.Width = 100
$toleranceBox.Location = New-Object System.Drawing.Point(116, 46)
$toleranceBox.Width = 78
$settingsGroup.Controls.Add($toleranceLabel)
$settingsGroup.Controls.Add($toleranceBox)

$observeLabel.Location = New-Object System.Drawing.Point(220, 22)
$observeLabel.Text = "Stable reads (samples)"
$observeLabel.Width = 130
$observeBox.Location = New-Object System.Drawing.Point(220, 46)
$observeBox.Width = 78
$observeBox.DecimalPlaces = 0
$observeBox.Minimum = 2
$observeBox.Maximum = 10
$observeBox.Increment = 1
$observeBox.Value = $script:StableConfirmSamples
$settingsGroup.Controls.Add($observeLabel)
$settingsGroup.Controls.Add($observeBox)

$stepLabel.Location = New-Object System.Drawing.Point(332, 22)
$stepLabel.Text = "Stable span (V)"
$stepLabel.Width = 110
$stepBox.Location = New-Object System.Drawing.Point(332, 46)
$stepBox.Width = 78
$stepBox.DecimalPlaces = 1
$stepBox.Minimum = 0.1
$stepBox.Maximum = 10
$stepBox.Increment = 0.1
$stepBox.Value = [decimal]$script:StableErrorSpanLimit
$settingsGroup.Controls.Add($stepLabel)
$settingsGroup.Controls.Add($stepBox)

$settingsTips.SetToolTip($intervalBox, "Monitor read interval in seconds. Calibration stability checks use the same pace between samples.")
$settingsTips.SetToolTip($toleranceBox, "Allowed final BUS voltage error. A channel is OK when channel voltage minus Target is within this range.")
$settingsTips.SetToolTip($observeBox, "Number of consecutive samples used for stable confirmation after each correction step.")
$settingsTips.SetToolTip($stepBox, "Maximum allowed error variation across the stable confirmation samples.")

$labels = @{}
$cardLayout = @(
    @{ Name = "VR"; X = 10; Y = 10; W = 305; H = 62 },
    @{ Name = "VS"; X = 325; Y = 10; W = 305; H = 62 },
    @{ Name = "VT"; X = 640; Y = 10; W = 305; H = 62 },
    @{ Name = "Target"; X = 10; Y = 82; W = 935; H = 62 }
)
foreach ($item in $cardLayout) {
    $card = New-Object System.Windows.Forms.GroupBox
    $card.Text = $item.Name
    $card.Location = [System.Drawing.Point]::new($item.X, $item.Y)
    $card.Size = New-Object System.Drawing.Size($item.W, $item.H)
    $leftPanel.Controls.Add($card)
    $val = New-Object System.Windows.Forms.Label
    $val.Text = "--"
    $val.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $val.TextAlign = "MiddleCenter"
    $val.Dock = "Fill"
    $card.Controls.Add($val)
    $labels[$item.Name] = $val
}

$barsGroup = New-Object System.Windows.Forms.GroupBox
$barsGroup.Text = "X CONTACTS - BUS Alignment"
$barsGroup.Location = New-Object System.Drawing.Point(10, 154)
$barsGroup.Size = New-Object System.Drawing.Size(935, 440)
$leftPanel.Controls.Add($barsGroup)

$bars = New-Object DoubleBufferedPanel
$bars.Dock = "Fill"
$bars.BackColor = [System.Drawing.Color]::White
$bars.Add_Paint({ Draw-Bars $this $_ })
$barsGroup.Controls.Add($bars)

$barsAnimationTimer = New-Object System.Windows.Forms.Timer
$barsAnimationTimer.Interval = 40
$barsAnimationTimer.Add_Tick({ Update-AnimatedErrors })

$trendGroup = New-Object System.Windows.Forms.GroupBox
$trendGroup.Text = "BUS Error Trend"
$trendGroup.Location = New-Object System.Drawing.Point(10, 610)
$trendGroup.Size = New-Object System.Drawing.Size(935, 165)
$leftPanel.Controls.Add($trendGroup)

$trend = New-Object DoubleBufferedPanel
$trend.Dock = "Fill"
$trend.BackColor = [System.Drawing.Color]::White
$trend.Add_Paint({ Draw-Trend $this $_ })
$trendGroup.Controls.Add($trend)

$statusGroup = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text = "Customer Status"
$statusGroup.Location = New-Object System.Drawing.Point(5, 0)
$statusGroup.Size = New-Object System.Drawing.Size(445, 78)
$rightPanel.Controls.Add($statusGroup)

$customerStatus = New-Object System.Windows.Forms.Label
$customerStatus.Text = "Ready"
$customerStatus.ForeColor = $Theme.Bad
$customerStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$customerStatus.Dock = "Fill"
$customerStatus.Padding = New-Object System.Windows.Forms.Padding(10)
$statusGroup.Controls.Add($customerStatus)

$manualGroup = New-Object System.Windows.Forms.GroupBox
$manualGroup.Text = "Manual Correction"
$manualGroup.Location = New-Object System.Drawing.Point(5, 230)
$manualGroup.Size = New-Object System.Drawing.Size(445, 150)
$rightPanel.Controls.Add($manualGroup)

$manualChannels = @("VDSPP", "VDSPN", "VMCUP", "VMCUN")
$manualRows = New-Object System.Collections.ArrayList
$manualCountLabels = @{}
for ($i = 0; $i -lt $manualChannels.Count; $i++) {
    $manualKey = $manualChannels[$i]
    $script:ManualPending[$manualKey] = 0
    $rowY = 25 + ([int][Math]::Floor($i / 2) * 58)
    $colX = 12 + (($i % 2) * 218)

    $manualLabel = New-Object System.Windows.Forms.Label
    $manualLabel.Text = $manualKey
    $manualLabel.Location = [System.Drawing.Point]::new($colX, $rowY + 8)
    $manualLabel.Width = 70
    $manualGroup.Controls.Add($manualLabel)

    $minusButton = New-Object System.Windows.Forms.Button
    $minusButton.Text = "-0.5V"
    $minusButton.Location = [System.Drawing.Point]::new($colX + 68, $rowY)
    $minusButton.Width = 58
    $minusButton.Tag = [pscustomobject]@{ Channel = $manualKey; Direction = -1 }
    $minusButton.Add_Click({
        param($sender, $eventArgs)
        Queue-ManualAdjustment $combo.SelectedItem $sender.Tag.Channel $sender.Tag.Direction
    }.GetNewClosure())
    $manualGroup.Controls.Add($minusButton)

    $minusCount = New-Object System.Windows.Forms.Label
    $minusCount.Text = "Count: 0"
    $minusCount.Location = [System.Drawing.Point]::new($colX + 68, $rowY + 28)
    $minusCount.Width = 58
    $minusCount.TextAlign = "MiddleCenter"
    $minusCount.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $manualGroup.Controls.Add($minusCount)
    $manualCountLabels["$manualKey-"] = $minusCount

    $plusButton = New-Object System.Windows.Forms.Button
    $plusButton.Text = "+0.5V"
    $plusButton.Location = [System.Drawing.Point]::new($colX + 132, $rowY)
    $plusButton.Width = 58
    $plusButton.Tag = [pscustomobject]@{ Channel = $manualKey; Direction = 1 }
    $plusButton.Add_Click({
        param($sender, $eventArgs)
        Queue-ManualAdjustment $combo.SelectedItem $sender.Tag.Channel $sender.Tag.Direction
    }.GetNewClosure())
    $manualGroup.Controls.Add($plusButton)

    $plusCount = New-Object System.Windows.Forms.Label
    $plusCount.Text = "Count: 0"
    $plusCount.Location = [System.Drawing.Point]::new($colX + 132, $rowY + 28)
    $plusCount.Width = 58
    $plusCount.TextAlign = "MiddleCenter"
    $plusCount.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $manualGroup.Controls.Add($plusCount)
    $manualCountLabels["$manualKey+"] = $plusCount

    [void]$manualRows.Add([pscustomobject]@{
        Label = $manualLabel
        Minus = $minusButton
        MinusCount = $minusCount
        Plus = $plusButton
        PlusCount = $plusCount
    })
}

$manualQueueTimer = New-Object System.Windows.Forms.Timer
$manualQueueTimer.Interval = 250
$manualQueueTimer.Add_Tick({ Process-ManualQueue })
Update-ManualCountLabels

$monitorReadTimer = New-Object System.Windows.Forms.Timer
$monitorReadTimer.Interval = 200

$logGroup = New-Object System.Windows.Forms.GroupBox
$logGroup.Text = "Event Log"
$logGroup.Location = New-Object System.Drawing.Point(5, 395)
$logGroup.Size = New-Object System.Drawing.Size(445, 190)
$rightPanel.Controls.Add($logGroup)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ScrollBars = "Both"
$log.WordWrap = $false
$log.ReadOnly = $true
$log.Font = New-Object System.Drawing.Font("Consolas", 9)
$log.Dock = "Fill"
$logGroup.Controls.Add($log)

$summaryGroup = New-Object System.Windows.Forms.GroupBox
$summaryGroup.Text = "Calibration Summary"
$summaryGroup.Location = New-Object System.Drawing.Point(5, 600)
$summaryGroup.Size = New-Object System.Drawing.Size(445, 170)
$rightPanel.Controls.Add($summaryGroup)

$summaryStatus = New-Object System.Windows.Forms.RichTextBox
$summaryStatus.Text = "No sample yet."
$summaryStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$summaryStatus.Dock = "Fill"
$summaryStatus.ReadOnly = $true
$summaryStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$summaryStatus.ScrollBars = "Vertical"
$summaryStatus.WordWrap = $false
$summaryStatus.Margin = New-Object System.Windows.Forms.Padding(8)
$summaryGroup.Controls.Add($summaryStatus)

function Update-MainLayout {
    $margin = 10
    $gap = 10
    $bodyY = $top.Height + $margin
    $bodyH = [Math]::Max(680, $form.ClientSize.Height - $bodyY - $margin)
    $rightW = [int]([Math]::Min(430, [Math]::Max(390, $form.ClientSize.Width * 0.30)))
    $leftW = [int]($form.ClientSize.Width - ($margin * 2) - $gap - $rightW)
    if ($leftW -lt 760) {
        $rightW = 370
        $leftW = [int]($form.ClientSize.Width - ($margin * 2) - $gap - $rightW)
    }

    $leftPanel.Location = [System.Drawing.Point]::new($margin, $bodyY)
    $leftPanel.Size = [System.Drawing.Size]::new($leftW, $bodyH)
    $rightPanel.Location = [System.Drawing.Point]::new($margin + $leftW + $gap, $bodyY)
    $rightPanel.Size = [System.Drawing.Size]::new($rightW, $bodyH)

    $innerW = $leftPanel.Width - 20
    $cardGap = 10
    $cardW = [int](($innerW - ($cardGap * 2)) / 3)
    $targetH = 58
    $metricH = 58

    $cardControls = @{}
    foreach ($card in $leftPanel.Controls) {
        if ($card -is [System.Windows.Forms.GroupBox] -and $card.Controls.Count -gt 0 -and $card.Controls[0] -is [System.Windows.Forms.Label]) {
            $cardControls[$card.Text] = $card
        }
    }
    if ($cardControls.ContainsKey("VR")) { $cardControls["VR"].Location = [System.Drawing.Point]::new(10, 8); $cardControls["VR"].Size = [System.Drawing.Size]::new($cardW, $metricH) }
    if ($cardControls.ContainsKey("VS")) { $cardControls["VS"].Location = [System.Drawing.Point]::new(10 + $cardW + $cardGap, 8); $cardControls["VS"].Size = [System.Drawing.Size]::new($cardW, $metricH) }
    if ($cardControls.ContainsKey("VT")) { $cardControls["VT"].Location = [System.Drawing.Point]::new(10 + (($cardW + $cardGap) * 2), 8); $cardControls["VT"].Size = [System.Drawing.Size]::new($cardW, $metricH) }
    if ($cardControls.ContainsKey("Target")) { $cardControls["Target"].Location = [System.Drawing.Point]::new(10, 74); $cardControls["Target"].Size = [System.Drawing.Size]::new($innerW, $targetH) }

    $barsY = 142
    $trendH = [int]([Math]::Min(220, [Math]::Max(170, $bodyH * 0.23)))
    $barsH = [int]($bodyH - $barsY - $trendH - 16)
    if ($barsH -lt 390) {
        $barsH = [Math]::Max(330, $bodyH - $barsY - 185 - 16)
        $trendH = [Math]::Max(150, $bodyH - $barsY - $barsH - 16)
    }
    $barsGroup.Location = [System.Drawing.Point]::new(10, $barsY)
    $barsGroup.Size = [System.Drawing.Size]::new($innerW, $barsH)
    $trendGroup.Location = [System.Drawing.Point]::new(10, $barsY + $barsH + 10)
    $trendGroup.Size = [System.Drawing.Size]::new($innerW, $trendH)

    $rightInnerW = $rightPanel.Width - 10
    $statusGroup.Location = [System.Drawing.Point]::new(5, 0)
    $statusGroup.Size = [System.Drawing.Size]::new($rightInnerW, 74)
    $settingsGroup.Location = [System.Drawing.Point]::new(5, 84)
    $settingsGroup.Size = [System.Drawing.Size]::new($rightInnerW, 118)
    $manualGroup.Location = [System.Drawing.Point]::new(5, 212)
    $manualGroup.Size = [System.Drawing.Size]::new($rightInnerW, 150)
    $summaryGroup.Location = [System.Drawing.Point]::new(5, 372)
    $summaryGroup.Size = [System.Drawing.Size]::new($rightInnerW, 190)
    $logGroup.Location = [System.Drawing.Point]::new(5, 572)
    $logGroup.Size = [System.Drawing.Size]::new($rightInnerW, [Math]::Max(120, $rightPanel.Height - 577))

    $manualColW = [int](($manualGroup.Width - 24) / 2)
    for ($i = 0; $i -lt $manualChannels.Count; $i++) {
        $rowY = 24 + ([int][Math]::Floor($i / 2) * 58)
        $colX = 12 + (($i % 2) * $manualColW)
        $row = $manualRows[$i]
        $buttonW = [Math]::Max(54, [Math]::Min(62, [int](($manualColW - 82) / 2)))
        $gapSmall = 8
        $minusX = $colX + 72
        $plusX = $minusX + $buttonW + $gapSmall
        $row.Label.Location = [System.Drawing.Point]::new($colX, $rowY + 7)
        $row.Label.Width = 64
        $row.Minus.Location = [System.Drawing.Point]::new($minusX, $rowY)
        $row.Minus.Width = $buttonW
        $row.MinusCount.Location = [System.Drawing.Point]::new($minusX, $rowY + 28)
        $row.MinusCount.Width = $buttonW
        $row.Plus.Location = [System.Drawing.Point]::new($plusX, $rowY)
        $row.Plus.Width = $buttonW
        $row.PlusCount.Location = [System.Drawing.Point]::new($plusX, $rowY + 28)
        $row.PlusCount.Width = $buttonW
    }

    $bars.Invalidate()
    $trend.Invalidate()
}

function Start-CalibrationFromUi {
    if (-not $combo.SelectedItem) {
        Write-Log "Please scan and select a COM port first."
        return
    }
    if ($script:CalibrationActive) {
        Write-Log "Calibration ignored: calibration is already running."
        return
    }
    $script:Tolerance = [double]$toleranceBox.Value
    $script:PostCorrectionSampleIntervalSeconds = [double]$intervalBox.Value
    $script:StableConfirmSamples = [int]$observeBox.Value
    $script:StableErrorSpanLimit = [double]$stepBox.Value
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Start BUS voltage calibration on $($combo.SelectedItem)?`r`nTolerance: +/-$($script:Tolerance)V`r`nCorrection step: fixed 0.5V`r`nStartup: auto boot every $($BootRetrySeconds)s until BUS is ready`r`nStable reads per channel: $($script:StableConfirmSamples)`r`nStable span limit: $($script:StableErrorSpanLimit)V`r`nFinal verification: 2 consecutive stable windows",
        "Confirm Calibration",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log "Calibration cancelled by user."
        return
    }
    $monitorWasActive = $script:MonitoringActive
    if ($monitorWasActive) {
        Write-Log "Monitor sampling paused while calibration uses the shared serial session."
    }
    $script:CalibrationActive = $true
    $combo.Enabled = $false
    $toleranceBox.Enabled = $false
    $intervalBox.Enabled = $false
    $observeBox.Enabled = $false
    $stepBox.Enabled = $false
    $scanButton.Enabled = $false
    $monitorButton.Enabled = $false
    $calibrateButton.Enabled = $false
    try {
        Calibrate-All $combo.SelectedItem
    } catch {
        Write-Log "Calibration failed: $($_.Exception.Message)"
        $customerStatus.Text = "Calibration failed. Check inverter startup, wiring, or COM connection."
        $customerStatus.ForeColor = $Theme.Bad
        $status.Text = "Ready"
        [System.Windows.Forms.MessageBox]::Show(
            "Calibration failed.`r`n`r`n$($_.Exception.Message)`r`n`r`nPlease confirm only AC Grid is connected before calibration.",
            "Calibration Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    } finally {
        $script:CalibrationActive = $false
        $scanButton.Enabled = $true
        $monitorButton.Enabled = $true
        $calibrateButton.Enabled = $true
        $toleranceBox.Enabled = $true
        $intervalBox.Enabled = $true
        $observeBox.Enabled = $true
        $stepBox.Enabled = $true
        if ($monitorWasActive -and $script:MonitoringActive) {
            $combo.Enabled = $false
            $script:NextMonitorRead = Get-Date
            $status.Text = "Running"
            Write-Log "Monitor sampling resumed after calibration."
        } else {
            $combo.Enabled = $true
            $status.Text = "Ready"
        }
    }
}

function Stop-Monitoring {
    if (-not $script:MonitoringActive) { return }
    $script:MonitoringActive = $false
    $monitorReadTimer.Stop()
    $monitorButton.Text = "Monitor"
    $combo.Enabled = $true
    $scanButton.Enabled = $true
    $calibrateButton.Enabled = $true
    if (-not $script:CalibrationActive) { $status.Text = "Ready" }
    Write-Log "Monitor stopped."
}

function Open-LogFolder {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
            [void](New-Item -ItemType Directory -Path $script:LogDirectory -Force)
        }
        $quotedPath = '"' + $script:LogDirectory + '"'
        Start-Process -FilePath "explorer.exe" -ArgumentList $quotedPath
        Write-Log "Opened log folder: $($script:LogDirectory)"
    } catch {
        Write-Log "Failed to open log folder: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to open the log folder.`r`n`r`n$($script:LogDirectory)`r`n`r`n$($_.Exception.Message)",
            "Open Logs Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Invoke-MonitorRead {
    if (-not $script:MonitoringActive) { return }
    if ($script:CalibrationActive -or $script:ManualQueueBusy -or $script:SerialOperationActive) { return }
    if ((Get-Date) -lt $script:NextMonitorRead) { return }

    $script:NextMonitorRead = (Get-Date).AddSeconds([double]$intervalBox.Value)
    try {
        # Monitor uses one attempt. A failed frame is retried on the next scheduled tick.
        $sample = Read-SampleOnce $combo.SelectedItem
        Update-SampleUi $sample
        Write-Log ("{0} target={1:N1}V VDSPP={2:N1}({3:+0.0;-0.0;0.0}) VDSPN={4:N1}({5:+0.0;-0.0;0.0}) VMCUP={6:N1}({7:+0.0;-0.0;0.0}) VMCUN={8:N1}({9:+0.0;-0.0;0.0})" -f $combo.SelectedItem, $sample.Target, $sample.VDSPP, ($sample.VDSPP - $sample.Target), $sample.VDSPN, ($sample.VDSPN - $sample.Target), $sample.VMCUP, ($sample.VMCUP - $sample.Target), $sample.VMCUN, ($sample.VMCUN - $sample.Target))
    } catch {
        Close-SerialConnection
        Write-Log "Monitor read failed; the shared session will reconnect on the next tick: $($_.Exception.Message)"
        $customerStatus.Text = "Monitor communication interrupted. Retrying automatically."
        $customerStatus.ForeColor = $Theme.Bad
    }
}

$monitorReadTimer.Add_Tick({ Invoke-MonitorRead })

$scanButton.Add_Click({
    if ($script:MonitoringActive -or $script:CalibrationActive) {
        Write-Log "Scan ignored: monitor or calibration is running."
        return
    }
    $status.Text = "Scanning"
    $combo.Items.Clear()
    Write-Log "Scanning serial ports..."
    foreach ($portName in [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) {
        if (Test-InverterPort $portName) {
            [void]$combo.Items.Add($portName)
            Write-Log "Correct port found: $portName"
        }
    }
    if ($combo.Items.Count -gt 0) {
        $combo.SelectedIndex = 0
        $customerStatus.Text = "Inverter connected on $($combo.SelectedItem)."
        $customerStatus.ForeColor = $Theme.Good
    } else {
        $customerStatus.Text = "No inverter COM port found."
        $customerStatus.ForeColor = $Theme.Bad
    }
    $status.Text = "Ready"
})

$monitorButton.Add_Click({
    if (-not $combo.SelectedItem) {
        Write-Log "Please scan and select a COM port first."
        return
    }
    if ($script:CalibrationActive) {
        Write-Log "Monitor control is temporarily unavailable during calibration."
        return
    }
    if ($script:MonitoringActive) {
        Stop-Monitoring
        return
    }
    $script:Tolerance = [double]$toleranceBox.Value
    $script:MonitoringActive = $true
    $script:NextMonitorRead = Get-Date
    $monitorButton.Text = "Stop Monitor"
    $combo.Enabled = $false
    $scanButton.Enabled = $false
    $calibrateButton.Enabled = $true
    $status.Text = "Running"
    Write-Log "Monitoring $($combo.SelectedItem) every $($intervalBox.Value)s..."
    $monitorReadTimer.Start()
    Invoke-MonitorRead
})

$calibrateButton.Add_Click({
    Start-CalibrationFromUi
})

$stopButton.Add_Click({
    if ($script:CalibrationActive) {
        $script:StopRequested = $true
        $status.Text = "Stopping"
    } elseif ($script:MonitoringActive) {
        Stop-Monitoring
    }
})

$openLogsButton.Add_Click({
    Open-LogFolder
})

$toleranceBox.Add_ValueChanged({
    $script:Tolerance = [double]$toleranceBox.Value
    $bars.Invalidate()
    if ($script:Latest) {
        Update-StatusPanels $script:Latest
    }
})

$combo.Add_SelectedIndexChanged({
    if ($script:SerialPortName -and $combo.SelectedItem -and $script:SerialPortName -ne [string]$combo.SelectedItem) {
        Close-SerialConnection
    }
})

Apply-ThemeRecursive $form
$top.BackColor = $Theme.Surface
$leftPanel.BackColor = $Theme.Window
$rightPanel.BackColor = $Theme.Window
$bars.BackColor = $Theme.Field
$trend.BackColor = $Theme.Field
$customerStatus.BackColor = $Theme.Surface
$log.BackColor = $Theme.Field
$log.ForeColor = $Theme.Text
$summaryStatus.BackColor = $Theme.Surface
$summaryStatus.ForeColor = $Theme.Muted
$status.ForeColor = $Theme.Accent

$form.Add_Resize({
    if ($leftPanel -and $rightPanel) {
        Update-MainLayout
    }
})
Update-MainLayout

$form.Add_Shown({
    $form.WindowState = "Normal"
    $form.Activate()
    $form.BringToFront()
    foreach ($p in [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) { [void]$combo.Items.Add($p) }
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    Write-Log "V0.7 batch correction GUI ready."
    $form.TopMost = $false
})

$form.Add_FormClosed({
    $monitorReadTimer.Stop()
    $manualQueueTimer.Stop()
    $barsAnimationTimer.Stop()
    Close-SerialConnection
})

[System.Windows.Forms.Application]::Run($form)



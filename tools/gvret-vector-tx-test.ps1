[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [ValidateRange(1, 4)][int]$VectorChannel = 1,
    [ValidateRange(10000, 1000000)][int]$ArbitrationBitrate = 500000,
    [ValidateRange(10000, 8000000)][int]$DataBitrate = 2000000,
    [ValidateRange(3, 3000)][int]$FrameCount = 600,
    [ValidateRange(2, 1000)][int]$IntervalMilliseconds = 10,
    [string]$VectorApiPath = 'C:\Program Files\Vector Hardware Manager\VHS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($FrameCount % 3 -ne 0) { throw 'FrameCount must be divisible by 3.' }
if ($DataBitrate -ne ($ArbitrationBitrate * 4)) {
    throw 'This firmware bench requires a 4x CAN FD data-rate factor.'
}

$vectorPath = [IO.Path]::GetFullPath($VectorApiPath)
$apiAssemblyPath = Join-Path $vectorPath 'Vector.XlApi.PniInternal.dll'
if (-not (Test-Path -LiteralPath $apiAssemblyPath)) {
    throw "Vector XL API assembly was not found: $apiAssemblyPath"
}
$env:PATH = $vectorPath + ';' + $env:PATH
[void][Reflection.Assembly]::LoadFrom($apiAssemblyPath)

function New-Payload {
    param([uint32]$Sequence, [int]$Length)
    $data = [byte[]]::new($Length)
    [BitConverter]::GetBytes($Sequence).CopyTo($data, 0)
    for ($i = 4; $i -lt $Length; $i++) {
        $data[$i] = [byte](($Sequence + [uint32]$i) -band 0xFF)
    }
    return $data
}

function Test-ByteSequence {
    param([byte[]]$Actual, [byte[]]$Expected)
    if ($Actual.Length -ne $Expected.Length) { return $false }
    for ($i = 0; $i -lt $Actual.Length; $i++) {
        if ($Actual[$i] -ne $Expected[$i]) { return $false }
    }
    return $true
}

function Write-CanSetup {
    param([System.IO.Ports.SerialPort]$Serial, [int]$Bitrate, [bool]$ListenOnly)
    $encoded = [uint32](0xC0000000L -bor [uint32]$Bitrate)
    if ($ListenOnly) { $encoded = $encoded -bor [uint32]0x20000000 }
    $packet = [Collections.Generic.List[byte]]::new()
    $packet.AddRange([byte[]]@(0xF1, 0x05))
    $packet.AddRange([BitConverter]::GetBytes($encoded))
    $packet.AddRange([byte[]]@(0, 0, 0, 0, 0))
    $Serial.Write($packet.ToArray(), 0, $packet.Count)
    Start-Sleep -Milliseconds 150
}

function Write-FdSetup {
    param([System.IO.Ports.SerialPort]$Serial, [int]$Bitrate, [bool]$Enabled)
    $packet = [Collections.Generic.List[byte]]::new()
    $packet.AddRange([byte[]]@(0xF1, 0x15, 0, [byte][int]$Enabled))
    $packet.AddRange([BitConverter]::GetBytes([uint32]$Bitrate))
    $packet.Add(0)
    $Serial.Write($packet.ToArray(), 0, $packet.Count)
    Start-Sleep -Milliseconds 150
}

function Write-GvretFrame {
    param(
        [System.IO.Ports.SerialPort]$Serial,
        [uint32]$CanId,
        [byte[]]$Payload,
        [bool]$Fd,
        [bool]$Brs
    )
    $packet = [Collections.Generic.List[byte]]::new()
    $packet.AddRange([byte[]]@(0xF1, $(if ($Fd) { 0x14 } else { 0x00 })))
    $packet.AddRange([BitConverter]::GetBytes($CanId))
    if ($Fd) {
        $packet.Add([byte]($Payload.Length -bor $(if ($Brs) { 0x80 } else { 0 })))
        $packet.Add(0) # local bus 0
    } else {
        $packet.Add(0) # local bus 0
        $packet.Add([byte]$Payload.Length)
    }
    $packet.AddRange($Payload)
    $packet.Add(0) # GVRET checksum placeholder
    $Serial.Write($packet.ToArray(), 0, $packet.Count)
}

function Read-ControllerStatus {
    param([System.IO.Ports.SerialPort]$Serial)
    $Serial.DiscardInBuffer()
    $query = [byte[]]@(0xF1, 0x17)
    $Serial.Write($query, 0, $query.Length)
    $bytes = [Collections.Generic.List[byte]]::new()
    $deadline = [DateTime]::UtcNow.AddMilliseconds(600)
    while ([DateTime]::UtcNow -lt $deadline) {
        $available = $Serial.BytesToRead
        if ($available -gt 0) {
            $buffer = [byte[]]::new($available)
            $count = $Serial.Read($buffer, 0, $buffer.Length)
            for ($i = 0; $i -lt $count; $i++) { $bytes.Add($buffer[$i]) }
        }
        for ($i = 0; $i -le ($bytes.Count - 17); $i++) {
            if ($bytes[$i] -eq 0xF1 -and $bytes[$i + 1] -eq 0x17) {
                $packet = $bytes.GetRange($i, 17).ToArray()
                $trec = [BitConverter]::ToUInt32($packet, 5)
                return [pscustomobject]@{
                    Flags = [int]$packet[4]
                    Mode = ([int]$packet[4] -shr 4) -band 0x07
                    TEC = [int](($trec -shr 8) -band 0xFF)
                    REC = [int]($trec -band 0xFF)
                    TREC = ('0x{0:X8}' -f $trec)
                    Diag0 = ('0x{0:X8}' -f [BitConverter]::ToUInt32($packet, 9))
                    Diag1 = ('0x{0:X8}' -f [BitConverter]::ToUInt32($packet, 13))
                }
            }
        }
        Start-Sleep -Milliseconds 2
    }
    throw 'No 0x17 controller-status response from the ESP.'
}

$xl = $null
$port = [Vector.XlApi.PniInternal.XlPortHandle]::Invalid
$serial = $null
$activated = $false
$channelMask = [uint64]0
$configured = $false
try {
    $serial = [System.IO.Ports.SerialPort]::new($PortName, 1000000, 'None', 8, 'One')
    $serial.DtrEnable = $false
    $serial.RtsEnable = $false
    $serial.ReadTimeout = 100
    $serial.WriteTimeout = 1000
    $serial.Open()
    Start-Sleep -Milliseconds 250
    Write-CanSetup -Serial $serial -Bitrate $ArbitrationBitrate -ListenOnly $false
    Write-FdSetup -Serial $serial -Bitrate $DataBitrate -Enabled $true
    $configured = $true
    $initial = Read-ControllerStatus -Serial $serial
    if (($initial.Flags -band 0x07) -ne 0x07 -or $initial.Mode -ne 0 -or
            $initial.TEC -ne 0 -or $initial.REC -ne 0) {
        throw "ESP not in clean normal FD mode: $($initial | Format-List | Out-String)"
    }

    $xl = [Vector.XlApi.PniInternal.Xl]::new()
    $channels = @(
        $xl.CreateDriverConfig().GetChannelConfig() |
            Where-Object { $_.vObjectIdentity -like '/device:VN1640/*' -and
                $_.hwChannel -ge 0 -and $_.hwChannel -lt 4 } |
            Sort-Object hwChannel
    )
    if ($channels.Count -ne 4) { throw "Expected four VN1640 channels, found $($channels.Count)." }
    $selected = $channels[$VectorChannel - 1]
    $channelMask = [uint64]1 -shl [int]$selected.channelIndex
    $permissionMask = $channelMask
    $port = $xl.OpenPort('CodexGvretTxVerification', $channelMask,
        [ref]$permissionMask, 65536,
        [Vector.XlApi.PniInternal.XlInterfaceVersion]::V4,
        [Vector.XlApi.PniInternal.XlBusType]::Can)
    if (($permissionMask -band $channelMask) -eq 0) {
        throw "Vector channel $VectorChannel is already initialized by another application."
    }
    $timing = [Vector.XlApi.PniInternal.XlCanFdConf]::new()
    $timing.arbitrationBitRate = [uint32]$ArbitrationBitrate
    $timing.sjwAbr = 2
    $timing.tseg1Abr = 63
    $timing.tseg2Abr = 16
    $timing.options = [Vector.XlApi.PniInternal.XlCanFdConfopt]0
    $timing.dataBitRate = [uint32]$DataBitrate
    $timing.sjwDbr = 2
    $timing.tseg1Dbr = 15
    $timing.tseg2Dbr = 4
    $xl.CanFdSetConfiguration($port, $channelMask, $timing)
    $xl.CanSetChannelOutput($port, $channelMask, [Vector.XlApi.PniInternal.XlOutputMode]::Normal)
    $xl.ActivateChannel($port, $channelMask,
        [Vector.XlApi.PniInternal.XlBusType]::Can,
        [Vector.XlApi.PniInternal.XlActivateFlag]::ResetClock)
    $activated = $true

    $event = [Vector.XlApi.PniInternal.XlCanRxEvent]::new()
    $seen = [Collections.Generic.HashSet[uint32]]::new()
    $counts = [int[]]::new(3)
    $invalid = 0
    $duplicates = 0
    $rxErrors = 0
    $txErrors = 0
    $guardFrames = [Collections.Generic.List[object]]::new()
    $phase = 'load'

    function Drain-Vector {
        while ($true) {
            $result = $xl.TryCanReceive($port, $event)
            if ($result -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) { break }
            if ($result -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
                throw "Vector receive failed: $result"
            }
            if ($event.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::RxError) {
                $script:rxErrors++
                continue
            }
            if ($event.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::TxError) {
                $script:txErrors++
                continue
            }
            if ($event.tag -ne [Vector.XlApi.PniInternal.XlCanEvTag]::RxOk) { continue }
            $id = [uint32]($event.tagData_canRxOkMsg_canId -band 0x1FFFFFFF)
            if ($script:phase -ne 'load') {
                if ($id -ge 0x600 -and $id -le 0x605) {
                    $length = if ($id -eq 0x603) { 8 } else { 12 }
                    $script:guardFrames.Add([pscustomobject]@{
                        Id = $id
                        Dlc = [int]$event.tagData_canRxOkMsg_dlc
                        Flags = $event.tagData_canRxOkMsg_msgFlags.ToString()
                        Data = [byte[]]$event.tagData_canRxOkMsg_data.ToArray(0, $length)
                    })
                }
                continue
            }
            if ($id -lt 0x600 -or $id -gt 0x602) { continue }
            $kind = [int]($id - 0x600)
            $expectedLength = @(8, 12, 64)[$kind]
            $expectedDlc = @(8, 9, 15)[$kind]
            $flags = $event.tagData_canRxOkMsg_msgFlags.ToString()
            $data = $event.tagData_canRxOkMsg_data.ToArray(0, $expectedLength)
            $sequence = [BitConverter]::ToUInt32($data, 0)
            $expectedData = New-Payload -Sequence $sequence -Length $expectedLength
            $payloadMatches = Test-ByteSequence -Actual $data -Expected $expectedData
            if ($sequence -ge $FrameCount -or ($sequence % 3) -ne $kind -or
                    $event.tagData_canRxOkMsg_dlc -ne $expectedDlc -or
                    ($flags.Contains('Edl') -ne ($kind -ne 0)) -or
                    ($flags.Contains('Brs') -ne ($kind -eq 2)) -or
                    (-not $payloadMatches)) {
                $script:invalid++
                continue
            }
            if (-not $script:seen.Add($sequence)) { $script:duplicates++; continue }
            $script:counts[$kind]++
        }
    }

    Write-Host "Sending $FrameCount ESP frames at $IntervalMilliseconds ms intervals (Classic 8, FD 12 no-BRS, FD 64 BRS)."
    $clock = [Diagnostics.Stopwatch]::StartNew()
    for ($sequence = 0; $sequence -lt $FrameCount; $sequence++) {
        $kind = $sequence % 3
        $length = @(8, 12, 64)[$kind]
        $payload = New-Payload -Sequence ([uint32]$sequence) -Length $length
        Write-GvretFrame -Serial $serial -CanId ([uint32](0x600 + $kind)) -Payload $payload `
            -Fd ($kind -ne 0) -Brs ($kind -eq 2)
        Drain-Vector
        $target = ($sequence + 1) * $IntervalMilliseconds
        while ($clock.ElapsedMilliseconds -lt $target) {
            Start-Sleep -Milliseconds 1
            Drain-Vector
        }
    }
    $sendSeconds = [Math]::Max($clock.Elapsed.TotalSeconds, 0.001)
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $deadline) {
        Drain-Vector
        Start-Sleep -Milliseconds 2
    }
    $afterLoad = Read-ControllerStatus -Serial $serial
    $load = [pscustomobject]@{
        Sent = $FrameCount
        Received = $seen.Count
        Classic8 = $counts[0]
        FD12NoBRS = $counts[1]
        FD64BRS = $counts[2]
        Lost = $FrameCount - $seen.Count
        Duplicates = $duplicates
        Invalid = $invalid
        VectorRxErrors = $rxErrors
        VectorTxErrors = $txErrors
        ESP_TEC = $afterLoad.TEC
        ESP_REC = $afterLoad.REC
        ESP_Mode = $afterLoad.Mode
        EffectiveFramesPerSecond = [Math]::Round($FrameCount / $sendSeconds, 1)
    }
    $load | Format-List
    if ($seen.Count -ne $FrameCount -or $duplicates -ne 0 -or $invalid -ne 0 -or
            $rxErrors -ne 0 -or $txErrors -ne 0 -or $afterLoad.TEC -ne 0 -or
            $afterLoad.REC -ne 0 -or $afterLoad.Mode -ne 0) {
        throw 'ESP -> Vector mixed load test failed.'
    }

    $phase = 'guard'
    Write-CanSetup -Serial $serial -Bitrate $ArbitrationBitrate -ListenOnly $true
    $listenStatus = Read-ControllerStatus -Serial $serial
    if (($listenStatus.Flags -band 0x08) -eq 0) { throw 'Listen-only mode not confirmed.' }
    Write-GvretFrame -Serial $serial -CanId 0x603 -Payload ([byte[]](0..7)) -Fd $false -Brs $false
    Write-GvretFrame -Serial $serial -CanId 0x604 -Payload ([byte[]](0..11)) -Fd $true -Brs $false
    Start-Sleep -Milliseconds 500
    Drain-Vector
    $listenOnlyObserved = $guardFrames.Count
    if ($listenOnlyObserved -ne 0) { throw "Listen-only leaked $listenOnlyObserved TX frames." }

    Write-CanSetup -Serial $serial -Bitrate $ArbitrationBitrate -ListenOnly $false
    Write-FdSetup -Serial $serial -Bitrate $DataBitrate -Enabled $false
    $fdOffStatus = Read-ControllerStatus -Serial $serial
    if (($fdOffStatus.Flags -band 0x07) -ne 0x03 -or $fdOffStatus.Mode -ne 6) {
        throw "FD-disabled Normal20B mode not confirmed: flags=$($fdOffStatus.Flags), mode=$($fdOffStatus.Mode)."
    }
    Write-GvretFrame -Serial $serial -CanId 0x604 -Payload ([byte[]](0..11)) -Fd $true -Brs $false
    Start-Sleep -Milliseconds 500
    Drain-Vector
    $fdOffObserved = $guardFrames.Count
    if ($fdOffObserved -ne 0) { throw "FD-disabled mode leaked $fdOffObserved TX frames." }
    Write-GvretFrame -Serial $serial -CanId 0x603 -Payload ([byte[]](0..7)) -Fd $false -Brs $false
    Start-Sleep -Milliseconds 500
    Drain-Vector
    $classicWhileFdOff = @($guardFrames | Where-Object { $_.Id -eq 0x603 })
    if ($guardFrames.Count -ne 1 -or $classicWhileFdOff.Count -ne 1 -or
            $classicWhileFdOff[0].Dlc -ne 8 -or
            $classicWhileFdOff[0].Flags.Contains('Edl') -or
            -not (Test-ByteSequence -Actual $classicWhileFdOff[0].Data -Expected ([byte[]](0..7)))) {
        throw "Expected exactly one intact Classic frame with FD disabled; observed $($guardFrames.Count) total frames."
    }

    Write-FdSetup -Serial $serial -Bitrate $DataBitrate -Enabled $true
    $restored = Read-ControllerStatus -Serial $serial
    if (($restored.Flags -band 0x0F) -ne 0x07 -or $restored.Mode -ne 0) {
        throw 'Normal FD mode was not restored.'
    }
    Write-GvretFrame -Serial $serial -CanId 0x605 -Payload ([byte[]](0..11)) -Fd $true -Brs $true
    Start-Sleep -Milliseconds 500
    Drain-Vector
    $restoredFrames = @($guardFrames | Where-Object { $_.Id -eq 0x605 })
    if ($guardFrames.Count -ne 2 -or $restoredFrames.Count -ne 1 -or
            $restoredFrames[0].Dlc -ne 9 -or
            -not $restoredFrames[0].Flags.Contains('Edl') -or
            -not $restoredFrames[0].Flags.Contains('Brs') -or
            -not (Test-ByteSequence -Actual $restoredFrames[0].Data -Expected ([byte[]](0..11)))) {
        throw "Expected one intact FD+BRS frame after restore; observed $($guardFrames.Count) total frames."
    }
    $finalStatus = Read-ControllerStatus -Serial $serial
    if (($finalStatus.Flags -band 0x0F) -ne 0x07 -or $finalStatus.Mode -ne 0 -or
            $finalStatus.TEC -ne 0 -or $finalStatus.REC -ne 0) {
        throw "ESP not clean after guard recovery: $($finalStatus | Format-List | Out-String)"
    }

    [pscustomobject]@{
        ListenOnlyConfirmed = $true
        ListenOnlyTXObserved = $listenOnlyObserved
        FDDisabledConfirmed = $true
        FDDisabledTXObserved = $fdOffObserved
        ClassicWhileFDDisabled = $classicWhileFdOff.Count
        NormalFDRestored = $true
        RestoredFDTXObserved = $restoredFrames.Count
        FinalESP_TEC = $finalStatus.TEC
        FinalESP_REC = $finalStatus.REC
        FinalESP_Diag0 = $finalStatus.Diag0
        FinalESP_Diag1 = $finalStatus.Diag1
    } | Format-List
    Write-Host '[PASS] ESP -> Vector load and TX guards.' -ForegroundColor Green
}
finally {
    if ($null -ne $serial -and $serial.IsOpen -and $configured) {
        try {
            Write-CanSetup -Serial $serial -Bitrate $ArbitrationBitrate -ListenOnly $false
            Write-FdSetup -Serial $serial -Bitrate $DataBitrate -Enabled $true
        } catch {
            Write-Warning "Could not restore ESP normal FD mode: $_"
        }
    }
    if ($activated -and $null -ne $xl -and
            $port -ne [Vector.XlApi.PniInternal.XlPortHandle]::Invalid) {
        $xl.DeactivateChannel($port, $channelMask)
    }
    if ($null -ne $xl -and
            $port -ne [Vector.XlApi.PniInternal.XlPortHandle]::Invalid) {
        $xl.ClosePort($port)
    }
    if ($null -ne $serial -and $serial.IsOpen) { $serial.Close() }
}

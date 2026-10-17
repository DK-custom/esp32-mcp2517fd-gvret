[CmdletBinding()]
param(
    [string]$PortName = 'COM4',

    [ValidateRange(1, 4)]
    [int]$VectorChannel = 1,

    [ValidateRange(10000, 1000000)]
    [int]$ArbitrationBitrate = 500000,

    [ValidateRange(10000, 8000000)]
    [int]$DataBitrate = 2000000,

    [ValidateRange(3, 100000)]
    [int]$FrameCount = 600,

    [ValidateRange(1, 1000)]
    [int]$IntervalMilliseconds = 2,

    [string]$VectorApiPath = 'C:\Program Files\Vector Hardware Manager\VHS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vectorPath = [IO.Path]::GetFullPath($VectorApiPath)
$apiAssemblyPath = Join-Path $vectorPath 'Vector.XlApi.PniInternal.dll'
if (-not (Test-Path -LiteralPath $apiAssemblyPath)) {
    throw "Vector XL API assembly was not found: $apiAssemblyPath"
}

$env:PATH = $vectorPath + ';' + $env:PATH
$apiAssembly = [Reflection.Assembly]::LoadFrom($apiAssemblyPath)

$fdDlcByLength = @{
    12 = 9
    64 = 15
}

function ConvertFrom-UInt32LE {
    param([uint32]$Value)
    return [BitConverter]::GetBytes($Value)
}

function Add-AvailableSerialBytes {
    param(
        [System.IO.Ports.SerialPort]$Serial,
        [Collections.Generic.List[byte]]$Destination
    )

    $available = $Serial.BytesToRead
    if ($available -le 0) { return }

    $chunk = [byte[]]::new($available)
    $read = $Serial.Read($chunk, 0, $chunk.Length)
    for ($index = 0; $index -lt $read; $index++) {
        $Destination.Add($chunk[$index])
    }
}

function Get-SequenceNumber {
    param([byte[]]$Payload)
    if ($Payload.Length -lt 4) { return $null }
    return [BitConverter]::ToUInt32($Payload, 0)
}

function Test-ByteSequence {
    param([byte[]]$Actual, [byte[]]$Expected)

    if ($Actual.Length -ne $Expected.Length) { return $false }
    for ($index = 0; $index -lt $Actual.Length; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) { return $false }
    }
    return $true
}

function Get-GvretFrames {
    param([byte[]]$Bytes)

    $frames = [Collections.Generic.List[object]]::new()
    $offset = 0
    while ($offset -lt ($Bytes.Length - 1)) {
        if ($Bytes[$offset] -ne 0xF1) {
            $offset++
            continue
        }

        $command = $Bytes[$offset + 1]
        if ($command -eq 0x00) {
            if (($offset + 10) -ge $Bytes.Length) { break }
            $length = $Bytes[$offset + 10] -band 0x0F
            $packetLength = 12 + $length
            $dataOffset = 11
            $brs = $false
        } elseif ($command -eq 0x14) {
            if (($offset + 11) -ge $Bytes.Length) { break }
            $length = $Bytes[$offset + 10] -band 0x7F
            $packetLength = 13 + $length
            $dataOffset = 12
            $brs = ($Bytes[$offset + 10] -band 0x80) -ne 0
        } else {
            # During this test the input buffer should contain frame reports only.
            # Advance one byte so a stray response cannot hide a later frame.
            $offset++
            continue
        }

        if (($offset + $packetLength) -gt $Bytes.Length) { break }
        $encodedId = [BitConverter]::ToUInt32($Bytes, $offset + 6)
        $payload = [byte[]]::new($length)
        if ($length -gt 0) {
            [Array]::Copy($Bytes, $offset + $dataOffset, $payload, 0, $length)
        }
        $frames.Add([pscustomobject]@{
            Command = $command
            CanId = $encodedId -band 0x1FFFFFFF
            Length = $length
            BitRateSwitch = $brs
            Payload = $payload
        })
        $offset += $packetLength
    }
    return $frames
}

function New-TestPayload {
    param([uint32]$Sequence, [int]$Length)

    $payload = [byte[]]::new($Length)
    [BitConverter]::GetBytes($Sequence).CopyTo($payload, 0)
    for ($index = 4; $index -lt $Length; $index++) {
        $payload[$index] = [byte](($Sequence + [uint32]$index) -band 0xFF)
    }
    return $payload
}

$xl = $null
$port = [Vector.XlApi.PniInternal.XlPortHandle]::Invalid
$serial = $null
$activated = $false

try {
    $serial = [System.IO.Ports.SerialPort]::new($PortName, 1000000, 'None', 8, 'One')
    $serial.DtrEnable = $false
    $serial.RtsEnable = $false
    $serial.ReadTimeout = 100
    $serial.WriteTimeout = 1000
    $serial.ReadBufferSize = 262144
    $serial.Open()
    Start-Sleep -Milliseconds 250

    # Enable GVRET bus 0 in normal mode at the requested arbitration rate.
    $encodedSettings = [uint32](0xC0000000L -bor [uint32]$ArbitrationBitrate)
    $canSetup = [Collections.Generic.List[byte]]::new()
    $canSetup.AddRange([byte[]]@(0xF1, 0x05))
    $canSetup.AddRange([byte[]](ConvertFrom-UInt32LE $encodedSettings))
    $canSetup.AddRange([byte[]]@(0, 0, 0, 0, 0))
    $serial.Write($canSetup.ToArray(), 0, $canSetup.Count)
    Start-Sleep -Milliseconds 150

    # Enable ISO CAN FD on bus 0 and select the data-phase bitrate.
    $fdSetup = [Collections.Generic.List[byte]]::new()
    $fdSetup.AddRange([byte[]]@(0xF1, 0x15, 0, 1))
    $fdSetup.AddRange([byte[]](ConvertFrom-UInt32LE ([uint32]$DataBitrate)))
    $fdSetup.Add(0)
    $serial.Write($fdSetup.ToArray(), 0, $fdSetup.Count)
    Start-Sleep -Milliseconds 250
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $xl = [Vector.XlApi.PniInternal.Xl]::new()
    $driverConfig = $xl.CreateDriverConfig()
    $physicalChannels = @(
        $driverConfig.GetChannelConfig() |
            Where-Object {
                $_.vObjectIdentity -like '/device:VN1640/*' -and
                $_.hwChannel -ge 0 -and $_.hwChannel -lt 4
            } |
            Sort-Object hwChannel
    )
    if ($physicalChannels.Count -ne 4) {
        throw "Expected four physical VN1640 CAN channels, found $($physicalChannels.Count)."
    }

    $selected = $physicalChannels[$VectorChannel - 1]
    $channelMask = [uint64]1 -shl [int]$selected.channelIndex
    $permissionMask = $channelMask
    $port = $xl.OpenPort(
        'CodexGvretVectorLoadTest',
        $channelMask,
        [ref]$permissionMask,
        65536,
        [Vector.XlApi.PniInternal.XlInterfaceVersion]::V4,
        [Vector.XlApi.PniInternal.XlBusType]::Can
    )
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
    $xl.ActivateChannel(
        $port,
        $channelMask,
        [Vector.XlApi.PniInternal.XlBusType]::Can,
        [Vector.XlApi.PniInternal.XlActivateFlag]::ResetClock
    )
    $activated = $true

    $arrayType = $apiAssembly.GetType('Vector.XlApi.PniInternal.XlArraySliceStruct`1').MakeGenericType(
        [Vector.XlApi.PniInternal.XlCanTxEvent]
    )
    $txArray = [Activator]::CreateInstance($arrayType, @([int]1))
    $rxEvent = [Vector.XlApi.PniInternal.XlCanRxEvent]::new()
    $serialBytes = [Collections.Generic.List[byte]]::new()
    $txOk = 0
    $txErrors = 0
    $rxErrors = 0
    $lastRxError = $null
    $lastBusStatus = $null
    $lastRxErrorCounter = $null
    $lastTxErrorCounter = $null

    $drainVector = {
        while ($true) {
            $status = $xl.TryCanReceive($port, $rxEvent)
            if ($status -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) { break }
            if ($status -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
                throw "Vector receive failed: $status"
            }
            if ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::TxOk) {
                $script:txOk++
            } elseif ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::TxError) {
                $script:txErrors++
            } elseif ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::RxError) {
                $script:rxErrors++
                $script:lastRxError = $rxEvent.tagData_canError_errorCode
            } elseif ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::ChipState) {
                $script:lastBusStatus = $rxEvent.tagData_canChipState_busStatus
                $script:lastRxErrorCounter = $rxEvent.tagData_canChipState_rxErrorCounter
                $script:lastTxErrorCounter = $rxEvent.tagData_canChipState_txErrorCounter
            }
        }
    }

    Write-Host ("Sending {0} mixed frames at {1} ms intervals: Classic 8, FD 12 no-BRS, FD 64 BRS." -f `
        $FrameCount, $IntervalMilliseconds)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    for ($sequence = 0; $sequence -lt $FrameCount; $sequence++) {
        $kind = $sequence % 3
        $length = if ($kind -eq 0) { 8 } elseif ($kind -eq 1) { 12 } else { 64 }
        $canId = [uint32](0x600 + $kind)
        $payload = New-TestPayload -Sequence ([uint32]$sequence) -Length $length

        $txEvent = [Vector.XlApi.PniInternal.XlCanTxEvent]::new()
        $txEvent.tag = [Vector.XlApi.PniInternal.XlCanEvTag]::TxMsg
        $txEvent.tagData_canMsg_canId = $canId
        $txEvent.tagData_canMsg_txAttempt = 1
        if ($kind -eq 0) {
            $txEvent.tagData_canMsg_dlc = [byte]$length
        } else {
            $flags = [Vector.XlApi.PniInternal.XlCanTxmsgFlag]::Edl
            if ($kind -eq 2) {
                $flags = $flags -bor [Vector.XlApi.PniInternal.XlCanTxmsgFlag]::Brs
            }
            $txEvent.tagData_canMsg_msgFlags = $flags
            $txEvent.tagData_canMsg_dlc = [byte]$fdDlcByLength[$length]
        }
        $txEvent.tagData_canMsg_data.CopyFrom($payload, 0, 0, $payload.Length)
        $txArray[0] = $txEvent
        $xl.CanTransmitEx($port, $channelMask, $txArray)

        & $drainVector
        Add-AvailableSerialBytes -Serial $serial -Destination $serialBytes

        $targetMilliseconds = ($sequence + 1) * $IntervalMilliseconds
        while ($clock.ElapsedMilliseconds -lt $targetMilliseconds) {
            Start-Sleep -Milliseconds 1
            & $drainVector
            Add-AvailableSerialBytes -Serial $serial -Destination $serialBytes
        }
    }
    $sendDurationSeconds = [Math]::Max($clock.Elapsed.TotalSeconds, 0.001)

    $drainDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $drainDeadline) {
        & $drainVector
        Add-AvailableSerialBytes -Serial $serial -Destination $serialBytes
        Start-Sleep -Milliseconds 2
    }

    $receivedFrames = @(Get-GvretFrames -Bytes $serialBytes.ToArray())
    $seen = [Collections.Generic.HashSet[uint32]]::new()
    $duplicates = 0
    $invalid = 0
    $classicReceived = 0
    $fdNoBrsReceived = 0
    $fdBrs64Received = 0

    foreach ($frame in $receivedFrames) {
        $sequence = Get-SequenceNumber -Payload $frame.Payload
        if ($null -eq $sequence -or $sequence -ge $FrameCount) {
            $invalid++
            continue
        }
        if (-not $seen.Add([uint32]$sequence)) {
            $duplicates++
            continue
        }

        $expectedKind = [int]($sequence % 3)
        $expectedId = [uint32](0x600 + $expectedKind)
        $expectedLength = if ($expectedKind -eq 0) { 8 } elseif ($expectedKind -eq 1) { 12 } else { 64 }
        $expectedCommand = if ($expectedKind -eq 0) { 0x00 } else { 0x14 }
        $expectedBrs = $expectedKind -eq 2
        $expectedPayload = New-TestPayload -Sequence $sequence -Length $expectedLength
        $payloadMatches = Test-ByteSequence -Actual $frame.Payload -Expected $expectedPayload
        if ($frame.CanId -ne $expectedId -or
                $frame.Length -ne $expectedLength -or
                $frame.Command -ne $expectedCommand -or
                $frame.BitRateSwitch -ne $expectedBrs -or
                -not $payloadMatches) {
            $invalid++
            continue
        }

        if ($expectedKind -eq 0) { $classicReceived++ }
        elseif ($expectedKind -eq 1) { $fdNoBrsReceived++ }
        else { $fdBrs64Received++ }
    }

    $serial.DiscardInBuffer()
    $statusQuery = [byte[]]@(0xF1, 0x17)
    $serial.Write($statusQuery, 0, $statusQuery.Length)
    $statusBytes = [Collections.Generic.List[byte]]::new()
    $statusDeadline = [DateTime]::UtcNow.AddMilliseconds(500)
    while ([DateTime]::UtcNow -lt $statusDeadline) {
        Add-AvailableSerialBytes -Serial $serial -Destination $statusBytes
        if ($statusBytes.Count -ge 17) { break }
        Start-Sleep -Milliseconds 2
    }
    $statusPacket = $null
    for ($offset = 0; $offset -le ($statusBytes.Count - 17); $offset++) {
        if ($statusBytes[$offset] -eq 0xF1 -and $statusBytes[$offset + 1] -eq 0x17) {
            $statusPacket = $statusBytes.GetRange($offset, 17).ToArray()
            break
        }
    }
    if ($null -eq $statusPacket) {
        throw 'Firmware did not return the GVRET controller-status response (0x17).'
    }
    $adapterFlags = $statusPacket[4]
    $operationMode = ($adapterFlags -shr 4) -band 0x07
    $trec = [BitConverter]::ToUInt32($statusPacket, 5)
    $diag0 = [BitConverter]::ToUInt32($statusPacket, 9)
    $diag1 = [BitConverter]::ToUInt32($statusPacket, 13)
    $receiveErrorCounter = [int]($trec -band 0xFF)
    $transmitErrorCounter = [int](($trec -shr 8) -band 0xFF)
    $errorWarning = ($trec -band (1 -shl 16)) -ne 0
    $receiveWarning = ($trec -band (1 -shl 17)) -ne 0
    $transmitWarning = ($trec -band (1 -shl 18)) -ne 0
    $receivePassive = ($trec -band (1 -shl 19)) -ne 0
    $transmitPassive = ($trec -band (1 -shl 20)) -ne 0
    $busOff = ($trec -band (1 -shl 21)) -ne 0

    $lost = $FrameCount - $seen.Count
    $result = [pscustomobject]@{
        Sent = $FrameCount
        VectorTxConfirmed = $txOk
        ReceivedByEspSerial = $seen.Count
        Lost = $lost
        Duplicates = $duplicates
        Invalid = $invalid
        Classic8Received = $classicReceived
        Fd12NoBrsReceived = $fdNoBrsReceived
        Fd64BrsReceived = $fdBrs64Received
        VectorTxErrors = $txErrors
        VectorRxErrors = $rxErrors
        LastVectorRxError = $lastRxError
        LastBusStatus = $lastBusStatus
        VectorRxErrorCounter = $lastRxErrorCounter
        VectorTxErrorCounter = $lastTxErrorCounter
        EspReceiveErrorCounter = $receiveErrorCounter
        EspTransmitErrorCounter = $transmitErrorCounter
        EspOperationMode = $operationMode
        EspErrorWarning = $errorWarning
        EspReceivePassive = $receivePassive
        EspTransmitPassive = $transmitPassive
        EspBusOff = $busOff
        EspDiag0 = ('0x{0:X8}' -f $diag0)
        EspDiag1 = ('0x{0:X8}' -f $diag1)
        EffectiveFramesPerSecond = [Math]::Round($FrameCount / $sendDurationSeconds, 1)
    }
    $result | Format-List

    $passed = $txOk -eq $FrameCount -and
        $seen.Count -eq $FrameCount -and
        $lost -eq 0 -and
        $duplicates -eq 0 -and
        $invalid -eq 0 -and
        $txErrors -eq 0 -and
        $rxErrors -eq 0 -and
        ($null -eq $lastRxErrorCounter -or $lastRxErrorCounter -eq 0) -and
        ($null -eq $lastTxErrorCounter -or $lastTxErrorCounter -eq 0) -and
        ($adapterFlags -band 0x07) -eq 0x07 -and
        $operationMode -eq 0 -and
        $receiveErrorCounter -eq 0 -and
        $transmitErrorCounter -eq 0 -and
        -not $errorWarning -and
        -not $receiveWarning -and
        -not $transmitWarning -and
        -not $receivePassive -and
        -not $transmitPassive -and
        -not $busOff
    if (-not $passed) {
        throw 'Mixed CAN/CAN FD load test failed; see counters above.'
    }
    Write-Host '[PASS] Mixed Classic/CAN FD load test completed with no loss or CAN errors.' -ForegroundColor Green
}
finally {
    if ($activated -and $null -ne $xl -and
            $port -ne [Vector.XlApi.PniInternal.XlPortHandle]::Invalid) {
        $xl.DeactivateChannel($port, $channelMask)
    }
    if ($null -ne $xl -and
            $port -ne [Vector.XlApi.PniInternal.XlPortHandle]::Invalid) {
        $xl.ClosePort($port)
    }
    if ($null -ne $serial -and $serial.IsOpen) {
        $serial.Close()
    }
}

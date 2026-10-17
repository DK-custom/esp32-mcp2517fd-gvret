[CmdletBinding()]
param(
    [string]$PortName = 'COM4',

    [ValidateRange(1, 4)]
    [int]$VectorChannel = 1,

    [ValidateRange(10000, 1000000)]
    [int]$Bitrate = 500000,

    [switch]$TestFdReceive,

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

function ConvertTo-UInt32LE {
    param([byte[]]$Bytes, [int]$Offset = 0)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function ConvertFrom-UInt32LE {
    param([uint32]$Value)
    return [BitConverter]::GetBytes($Value)
}

function Read-SerialBytes {
    param(
        [System.IO.Ports.SerialPort]$Serial,
        [int]$Milliseconds
    )

    $result = [Collections.Generic.List[byte]]::new()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $available = $Serial.BytesToRead
        if ($available -gt 0) {
            $chunk = [byte[]]::new($available)
            $read = $Serial.Read($chunk, 0, $chunk.Length)
            for ($index = 0; $index -lt $read; $index++) {
                $result.Add($chunk[$index])
            }
        } else {
            Start-Sleep -Milliseconds 2
        }
    }
    return $result.ToArray()
}

function Find-GvretPacket {
    param(
        [byte[]]$Bytes,
        [byte]$Command
    )

    for ($offset = 0; $offset -lt ($Bytes.Length - 1); $offset++) {
        if ($Bytes[$offset] -ne 0xF1 -or $Bytes[$offset + 1] -ne $Command) {
            continue
        }

        $packetLength = switch ($Command) {
            0x00 {
                if (($offset + 10) -ge $Bytes.Length) { continue }
                12 + ($Bytes[$offset + 10] -band 0x0F)
            }
            0x14 {
                if (($offset + 11) -ge $Bytes.Length) { continue }
                13 + ($Bytes[$offset + 10] -band 0x7F)
            }
            0x06 { 12 }
            default { throw "Unsupported GVRET response command 0x$($Command.ToString('X2'))." }
        }

        if (($offset + $packetLength) -le $Bytes.Length) {
            $packet = [byte[]]::new($packetLength)
            [Array]::Copy($Bytes, $offset, $packet, 0, $packetLength)
            return $packet
        }
    }
    return $null
}

function Test-ByteSequence {
    param([byte[]]$Actual, [byte[]]$Expected)
    if ($Actual.Length -ne $Expected.Length) { return $false }
    for ($index = 0; $index -lt $Actual.Length; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) { return $false }
    }
    return $true
}

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Details)
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}: {2}" -f $status, $Name, $Details) -ForegroundColor $color
}

$xl = $null
$port = $null
$serial = $null
$activated = $false
$failures = [Collections.Generic.List[string]]::new()

try {
    $serial = [System.IO.Ports.SerialPort]::new($PortName, 1000000, 'None', 8, 'One')
    $serial.DtrEnable = $false
    $serial.RtsEnable = $false
    $serial.ReadTimeout = 100
    $serial.WriteTimeout = 1000
    $serial.Open()
    Start-Sleep -Milliseconds 250
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    # GVRET command 0x05: enable bus 0, normal mode, requested arbitration bitrate.
    $encodedSettings = [uint32](0xC0000000L -bor [uint32]$Bitrate)
    $setup = [Collections.Generic.List[byte]]::new()
    $setup.AddRange([byte[]]@(0xF1, 0x05))
    $setup.AddRange([byte[]](ConvertFrom-UInt32LE $encodedSettings))
    $setup.AddRange([byte[]]@(0, 0, 0, 0, 0))
    $serial.Write($setup.ToArray(), 0, $setup.Count)
    Start-Sleep -Milliseconds 250

    # Read settings back from the firmware before touching the CAN bus.
    $serial.DiscardInBuffer()
    $getSettings = [byte[]]@(0xF1, 0x06)
    $serial.Write($getSettings, 0, $getSettings.Length)
    $settingsBytes = Read-SerialBytes -Serial $serial -Milliseconds 500
    $settingsPacket = Find-GvretPacket -Bytes $settingsBytes -Command 0x06
    $settingsOk = $null -ne $settingsPacket -and
        ($settingsPacket[2] -band 0x01) -ne 0 -and
        ($settingsPacket[2] -band 0x10) -eq 0 -and
        (ConvertTo-UInt32LE $settingsPacket 3) -eq [uint32]$Bitrate
    if ($settingsOk) {
        Write-TestResult 'GVRET configuration' $true "bus 0 enabled, normal mode, $Bitrate bit/s"
    } else {
        Write-TestResult 'GVRET configuration' $false 'firmware did not confirm the requested active bus settings'
        $failures.Add('GVRET configuration')
    }

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
        'CodexGvretVectorBench',
        $channelMask,
        [ref]$permissionMask,
        32768,
        [Vector.XlApi.PniInternal.XlInterfaceVersion]::V4,
        [Vector.XlApi.PniInternal.XlBusType]::Can
    )
    if (($permissionMask -band $channelMask) -eq 0) {
        throw "Vector channel $VectorChannel is already initialized by another application."
    }

    $timing = [Vector.XlApi.PniInternal.XlCanFdConf]::new()
    $timing.arbitrationBitRate = [uint32]$Bitrate
    $timing.sjwAbr = 2
    $timing.tseg1Abr = 63
    $timing.tseg2Abr = 16
    if ($TestFdReceive) {
        $timing.options = [Vector.XlApi.PniInternal.XlCanFdConfopt]0
        $timing.dataBitRate = [uint32]($Bitrate * 4)
        $timing.sjwDbr = 2
        $timing.tseg1Dbr = 15
        $timing.tseg2Dbr = 4
    } else {
        $timing.options = [Vector.XlApi.PniInternal.XlCanFdConfopt]::Can20
        $timing.dataBitRate = 0
    }
    $xl.CanFdSetConfiguration($port, $channelMask, $timing)
    $xl.CanSetChannelOutput($port, $channelMask, [Vector.XlApi.PniInternal.XlOutputMode]::Normal)
    $xl.ActivateChannel(
        $port,
        $channelMask,
        [Vector.XlApi.PniInternal.XlBusType]::Can,
        [Vector.XlApi.PniInternal.XlActivateFlag]::ResetClock
    )
    $activated = $true

    # Direction 1: Vector -> CAN -> MCP2517FD/ESP32 -> GVRET serial.
    $vectorToEspId = [uint32]0x456
    $vectorToEspData = [byte[]]@(0xA1, 0xB2, 0xC3, 0xD4, 0xE5)
    $serial.DiscardInBuffer()

    $txEvent = [Vector.XlApi.PniInternal.XlCanTxEvent]::new()
    $txEvent.tag = [Vector.XlApi.PniInternal.XlCanEvTag]::TxMsg
    $txEvent.tagData_canMsg_canId = $vectorToEspId
    $txEvent.tagData_canMsg_dlc = [byte]$vectorToEspData.Length
    $txEvent.tagData_canMsg_txAttempt = 1
    $txEvent.tagData_canMsg_data.CopyFrom($vectorToEspData, 0, 0, $vectorToEspData.Length)
    $arrayType = $apiAssembly.GetType('Vector.XlApi.PniInternal.XlArraySliceStruct`1').MakeGenericType(
        [Vector.XlApi.PniInternal.XlCanTxEvent]
    )
    $txArray = [Activator]::CreateInstance($arrayType, @([int]1))
    $txArray[0] = $txEvent
    $xl.CanTransmitEx($port, $channelMask, $txArray)

    $rxEvent = [Vector.XlApi.PniInternal.XlCanRxEvent]::new()
    $txConfirmed = $false
    $txDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $txDeadline) {
        $status = $xl.TryCanReceive($port, $rxEvent)
        if ($status -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) {
            Start-Sleep -Milliseconds 2
            continue
        }
        if ($status -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
            throw "Vector receive failed after transmit: $status"
        }
        if ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::TxOk) {
            $txConfirmed = $true
            break
        }
    }

    $serialBytes = Read-SerialBytes -Serial $serial -Milliseconds 750
    $gvretFrame = Find-GvretPacket -Bytes $serialBytes -Command 0x00
    $forwardedId = if ($null -ne $gvretFrame) { (ConvertTo-UInt32LE $gvretFrame 6) -band 0x1FFFFFFF } else { 0 }
    $forwardedLength = if ($null -ne $gvretFrame) { $gvretFrame[10] -band 0x0F } else { 0 }
    $forwardedData = if ($null -ne $gvretFrame) {
        [byte[]]$gvretFrame[11..(10 + $forwardedLength)]
    } else {
        [byte[]]@()
    }
    $vectorToEspOk = $txConfirmed -and
        $null -ne $gvretFrame -and
        $forwardedId -eq $vectorToEspId -and
        $forwardedLength -eq $vectorToEspData.Length -and
        (Test-ByteSequence $forwardedData $vectorToEspData)
    Write-TestResult 'Vector -> ESP -> COM' $vectorToEspOk (
        "ID 0x{0:X3}, data {1}, Vector TX acknowledged={2}" -f
        $forwardedId, [BitConverter]::ToString($forwardedData), $txConfirmed
    )
    if (-not $vectorToEspOk) { $failures.Add('Vector -> ESP -> COM') }

    # Direction 2: GVRET serial -> ESP32/MCP2517FD -> CAN -> Vector.
    while ($xl.TryCanReceive($port, $rxEvent) -eq [Vector.XlApi.PniInternal.XlStatus]::Success) { }
    $espToVectorId = [uint32]0x321
    $espToVectorData = [byte[]]@(0x11, 0x22, 0x33, 0x44)
    $gvretTx = [Collections.Generic.List[byte]]::new()
    $gvretTx.AddRange([byte[]]@(0xF1, 0x00))
    $gvretTx.AddRange([byte[]](ConvertFrom-UInt32LE $espToVectorId))
    $gvretTx.Add(0)
    $gvretTx.Add([byte]$espToVectorData.Length)
    $gvretTx.AddRange($espToVectorData)
    $gvretTx.Add(0)
    $serial.Write($gvretTx.ToArray(), 0, $gvretTx.Count)

    $receivedId = [uint32]0
    $receivedData = [byte[]]@()
    $espToVectorReceived = $false
    $receiveDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $receiveDeadline) {
        $status = $xl.TryCanReceive($port, $rxEvent)
        if ($status -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) {
            Start-Sleep -Milliseconds 2
            continue
        }
        if ($status -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
            throw "Vector receive failed while waiting for the ESP frame: $status"
        }
        if ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::RxOk) {
            $candidateId = $rxEvent.tagData_canRxOkMsg_canId -band 0x1FFFFFFF
            $candidateLength = [int]$rxEvent.tagData_canRxOkMsg_dlc
            $candidateData = $rxEvent.tagData_canRxOkMsg_data.ToArray(0, $candidateLength)
            if ($candidateId -eq $espToVectorId) {
                $receivedId = $candidateId
                $receivedData = $candidateData
                $espToVectorReceived = $true
                break
            }
        }
    }

    $espToVectorOk = $espToVectorReceived -and (Test-ByteSequence $receivedData $espToVectorData)
    Write-TestResult 'COM -> ESP -> Vector' $espToVectorOk (
        "ID 0x{0:X3}, data {1}, active ACK enabled" -f
        $receivedId, [BitConverter]::ToString($receivedData)
    )
    if (-not $espToVectorOk) { $failures.Add('COM -> ESP -> Vector') }

    if ($TestFdReceive) {
        # The adapter uses x4 data bitrate. This first FD frame has no BRS.
        $fdId = [uint32]0x5A5
        $fdData = [byte[]]@(0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB)
        $serial.DiscardInBuffer()

        $fdTxEvent = [Vector.XlApi.PniInternal.XlCanTxEvent]::new()
        $fdTxEvent.tag = [Vector.XlApi.PniInternal.XlCanEvTag]::TxMsg
        $fdTxEvent.tagData_canMsg_canId = $fdId
        $fdTxEvent.tagData_canMsg_msgFlags = [Vector.XlApi.PniInternal.XlCanTxmsgFlag]::Edl
        $fdTxEvent.tagData_canMsg_dlc = 9  # CAN FD DLC 9 represents 12 data bytes.
        $fdTxEvent.tagData_canMsg_txAttempt = 1
        $fdTxEvent.tagData_canMsg_data.CopyFrom($fdData, 0, 0, $fdData.Length)
        $fdTxArray = [Activator]::CreateInstance($arrayType, @([int]1))
        $fdTxArray[0] = $fdTxEvent
        $xl.CanTransmitEx($port, $channelMask, $fdTxArray)

        $fdTxConfirmed = $false
        $fdDeadline = [DateTime]::UtcNow.AddSeconds(2)
        while ([DateTime]::UtcNow -lt $fdDeadline) {
            $status = $xl.TryCanReceive($port, $rxEvent)
            if ($status -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) {
                Start-Sleep -Milliseconds 2
                continue
            }
            if ($status -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
                throw "Vector receive failed after CAN FD transmit: $status"
            }
            if ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::TxOk) {
                $fdTxConfirmed = $true
                break
            }
        }

        $fdSerialBytes = Read-SerialBytes -Serial $serial -Milliseconds 750
        $fdPacket = Find-GvretPacket -Bytes $fdSerialBytes -Command 0x14
        $forwardedFdId = if ($null -ne $fdPacket) { (ConvertTo-UInt32LE $fdPacket 6) -band 0x1FFFFFFF } else { 0 }
        $forwardedFdLength = if ($null -ne $fdPacket) { $fdPacket[10] -band 0x7F } else { 0 }
        $forwardedFdBus = if ($null -ne $fdPacket) { $fdPacket[11] } else { 0xFF }
        $forwardedFdData = if ($null -ne $fdPacket) {
            [byte[]]$fdPacket[12..(11 + $forwardedFdLength)]
        } else {
            [byte[]]@()
        }
        $fdReceiveOk = $fdTxConfirmed -and
            $null -ne $fdPacket -and
            $forwardedFdId -eq $fdId -and
            $forwardedFdLength -eq $fdData.Length -and
            $forwardedFdBus -eq 0 -and
            (Test-ByteSequence $forwardedFdData $fdData)
        Write-TestResult 'Vector FD -> ESP -> COM' $fdReceiveOk (
            "ID 0x{0:X3}, length {1}, data {2}, BRS=False" -f
            $forwardedFdId, $forwardedFdLength, [BitConverter]::ToString($forwardedFdData)
        )
        if (-not $fdReceiveOk) { $failures.Add('Vector FD -> ESP -> COM') }

        # Direction 4: GVRET FD -> ESP -> CAN -> Vector, 12/32/64 bytes and BRS.
        foreach ($test in @(
            @{ Id = [uint32]0x5A6; Data = [byte[]](0..11); Brs = $false },
            @{ Id = [uint32]0x5A8; Data = [byte[]](0..31); Brs = $true },
            @{ Id = [uint32]0x5A7; Data = [byte[]](0..63); Brs = $true }
        )) {
            while ($xl.TryCanReceive($port, $rxEvent) -eq [Vector.XlApi.PniInternal.XlStatus]::Success) { }
            $gvretFdTx = [Collections.Generic.List[byte]]::new()
            $gvretFdTx.AddRange([byte[]]@(0xF1, 0x14))
            $gvretFdTx.AddRange([byte[]](ConvertFrom-UInt32LE $test.Id))
            $gvretFdTx.Add([byte]($test.Data.Length -bor $(if ($test.Brs) { 0x80 } else { 0 })))
            $gvretFdTx.Add(0) # bus 0
            $gvretFdTx.AddRange($test.Data)
            $gvretFdTx.Add(0) # checksum placeholder
            $serial.Write($gvretFdTx.ToArray(), 0, $gvretFdTx.Count)

            $received = $false
            $flags = ''
            $receivedData = [byte[]]@()
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            while ([DateTime]::UtcNow -lt $deadline) {
                $status = $xl.TryCanReceive($port, $rxEvent)
                if ($status -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) {
                    Start-Sleep -Milliseconds 2
                    continue
                }
                if ($status -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
                    throw "Vector receive failed while waiting for FD frame: $status"
                }
                if ($rxEvent.tag -ne [Vector.XlApi.PniInternal.XlCanEvTag]::RxOk -or
                        ($rxEvent.tagData_canRxOkMsg_canId -band 0x1FFFFFFF) -ne $test.Id) {
                    continue
                }
                $received = $true
                $flags = $rxEvent.tagData_canRxOkMsg_msgFlags.ToString()
                $receivedData = $rxEvent.tagData_canRxOkMsg_data.ToArray(0, $test.Data.Length)
                break
            }
            $fdTransmitOk = $received -and $flags.Contains('Edl') -and
                ($flags.Contains('Brs') -eq $test.Brs) -and
                (Test-ByteSequence $receivedData $test.Data)
            Write-TestResult 'COM FD -> ESP -> Vector' $fdTransmitOk (
                'ID 0x{0:X3}, length {1}, BRS={2}, received={3}, flags={4}' -f
                $test.Id, $test.Data.Length, $test.Brs, $received, $flags)
            if (-not $fdTransmitOk) { $failures.Add(('COM FD -> ESP -> Vector 0x{0:X3}' -f $test.Id)) }
        }
    }
}
finally {
    if ($activated -and $null -ne $xl -and $null -ne $port) {
        $xl.DeactivateChannel($port, $channelMask)
    }
    if ($null -ne $xl -and $null -ne $port -and
        $port -ne [Vector.XlApi.PniInternal.XlPortHandle]::Invalid) {
        $xl.ClosePort($port)
    }
    if ($null -ne $serial -and $serial.IsOpen) {
        $serial.Close()
    }
}

if ($failures.Count -gt 0) {
    throw "Bench test failed: $($failures -join ', ')"
}

$summary = if ($TestFdReceive) {
    'Complete classic and CAN FD bidirectional bench test passed.'
} else {
    'Complete classic CAN bench test passed in both directions.'
}
Write-Host "[PASS] $summary" -ForegroundColor Green

[CmdletBinding()]
param(
    [ValidateSet('Info', 'Monitor', 'MonitorActive', 'SendClassic', 'SendFd')]
    [string]$Mode = 'Info',

    [ValidateRange(1, 4)]
    [int]$Channel = 1,

    [ValidateRange(10000, 1000000)]
    [int]$ArbitrationBitrate = 500000,

    [ValidateRange(0, 8000000)]
    [int]$DataBitrate = 2000000,

    [ValidateRange(1, 86400)]
    [int]$Seconds = 10,

    [switch]$SummaryOnly,

    [ValidateRange(0, 0x7FF)]
    [uint32]$MonitorId = 0,

    [ValidateRange(0, 0x7FF)]
    [uint32]$CanId = 0x123,

    [ValidateCount(0, 64)]
    [byte[]]$Data = @(0x43, 0x4F, 0x44, 0x45, 0x58, 0x01, 0x02, 0x03),

    [switch]$BitRateSwitch,

    [string]$VectorApiPath = 'C:\Program Files\Vector Hardware Manager\VHS'
)

$ErrorActionPreference = 'Stop'

$vectorPath = [IO.Path]::GetFullPath($VectorApiPath)
$apiAssemblyPath = Join-Path $vectorPath 'Vector.XlApi.PniInternal.dll'

if (-not (Test-Path -LiteralPath $apiAssemblyPath)) {
    throw "Vector XL API assembly was not found: $apiAssemblyPath"
}

$env:PATH = $vectorPath + ';' + $env:PATH
$apiAssembly = [Reflection.Assembly]::LoadFrom($apiAssemblyPath)

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

if ($Mode -eq 'Info') {
    $device = @($driverConfig.GetDeviceConfig() | Where-Object { $_.vObjectIdentity -eq '/device:VN1640/hwindex:0' })[0]
    [pscustomobject]@{
        Device        = $device.name
        Serial        = $device.serialNumber
        Driver        = $device.driverVersion
        Firmware      = $device.fwVersion
        Configuration = $device.configStatus
    } | Format-List

    $physicalChannels | ForEach-Object {
        [pscustomobject]@{
            Channel       = $_.hwChannel + 1
            GlobalIndex   = $_.channelIndex
            Transceiver   = $_.transceiver.name
            CANFD         = $_.channelCapabilities.ToString().Contains('CanfdIsoSupport')
            CurrentMode   = $_.busParams.data_can_canOpMode
            CurrentBitrate = $_.busParams.data_can_actualBitRate
            OnBus         = $_.isOnBus
        }
    } | Format-Table -AutoSize
    return
}

$selected = $physicalChannels[$Channel - 1]
$effectiveDataBitrate = if ($Mode -eq 'SendClassic') { 0 } else { $DataBitrate }

if ($Mode -eq 'SendClassic' -and $Data.Length -gt 8) {
    throw 'Classic CAN payload cannot exceed 8 bytes.'
}

$fdDlcByLength = @{
    0 = 0; 1 = 1; 2 = 2; 3 = 3; 4 = 4; 5 = 5; 6 = 6; 7 = 7; 8 = 8
    12 = 9; 16 = 10; 20 = 11; 24 = 12; 32 = 13; 48 = 14; 64 = 15
}
if ($Mode -eq 'SendFd' -and -not $fdDlcByLength.ContainsKey($Data.Length)) {
    throw 'CAN FD payload length must be 0..8, 12, 16, 20, 24, 32, 48, or 64 bytes.'
}
$channelMask = [uint64]1 -shl [int]$selected.channelIndex
$permissionMask = $channelMask
$port = [Vector.XlApi.PniInternal.XlPortHandle]::Invalid
$activated = $false

try {
    $port = $xl.OpenPort(
        'CodexVectorMonitor',
        $channelMask,
        [ref]$permissionMask,
        32768,
        [Vector.XlApi.PniInternal.XlInterfaceVersion]::V4,
        [Vector.XlApi.PniInternal.XlBusType]::Can
    )

    if (($permissionMask -band $channelMask) -eq 0) {
        throw "Channel $Channel is already initialized by another application. Close that application and retry."
    }

    $timing = [Vector.XlApi.PniInternal.XlCanFdConf]::new()
    $timing.arbitrationBitRate = [uint32]$ArbitrationBitrate
    $timing.sjwAbr = 2
    $timing.tseg1Abr = 63
    $timing.tseg2Abr = 16

    if ($effectiveDataBitrate -eq 0) {
        $timing.options = [Vector.XlApi.PniInternal.XlCanFdConfopt]::Can20
        $timing.dataBitRate = 0
    } else {
        $timing.options = [Vector.XlApi.PniInternal.XlCanFdConfopt]0
        $timing.dataBitRate = [uint32]$effectiveDataBitrate
        $timing.sjwDbr = 2
        $timing.tseg1Dbr = 15
        $timing.tseg2Dbr = 4
    }

    $xl.CanFdSetConfiguration($port, $channelMask, $timing)
    $outputMode = if ($Mode -eq 'Monitor') {
        [Vector.XlApi.PniInternal.XlOutputMode]::Silent
    } else {
        [Vector.XlApi.PniInternal.XlOutputMode]::Normal
    }
    $xl.CanSetChannelOutput($port, $channelMask, $outputMode)
    $xl.ActivateChannel(
        $port,
        $channelMask,
        [Vector.XlApi.PniInternal.XlBusType]::Can,
        [Vector.XlApi.PniInternal.XlActivateFlag]::ResetClock
    )
    $activated = $true

    if ($Mode -in @('SendClassic', 'SendFd')) {
        $txEvent = [Vector.XlApi.PniInternal.XlCanTxEvent]::new()
        $txEvent.tag = [Vector.XlApi.PniInternal.XlCanEvTag]::TxMsg
        $txEvent.tagData_canMsg_canId = $CanId
        if ($Mode -eq 'SendFd') {
            $fdFlags = [Vector.XlApi.PniInternal.XlCanTxmsgFlag]::Edl
            if ($BitRateSwitch) {
                $fdFlags = $fdFlags -bor [Vector.XlApi.PniInternal.XlCanTxmsgFlag]::Brs
            }
            $txEvent.tagData_canMsg_msgFlags = $fdFlags
            $txEvent.tagData_canMsg_dlc = [byte]$fdDlcByLength[$Data.Length]
        } else {
            $txEvent.tagData_canMsg_dlc = [byte]$Data.Length
        }
        $txEvent.tagData_canMsg_txAttempt = 1
        $txEvent.tagData_canMsg_data.CopyFrom($Data, 0, 0, $Data.Length)

        $arrayType = $apiAssembly.GetType('Vector.XlApi.PniInternal.XlArraySliceStruct`1').MakeGenericType(
            [Vector.XlApi.PniInternal.XlCanTxEvent]
        )
        $txArray = [Activator]::CreateInstance($arrayType, @([int]1))
        $txArray[0] = $txEvent

        $frameKind = if ($Mode -eq 'SendFd') {
            "CAN FD frame (data $DataBitrate bit/s, BRS=$([bool]$BitRateSwitch))"
        } else {
            'classic CAN frame'
        }
        Write-Host ('Sending one {0}: channel {1}, arbitration {2} bit/s, ID 0x{3:X3}, data {4}' -f `
            $frameKind, $Channel, $ArbitrationBitrate, $CanId, [BitConverter]::ToString($Data))
        $xl.CanTransmitEx($port, $channelMask, $txArray)

        $rxEvent = [Vector.XlApi.PniInternal.XlCanRxEvent]::new()
        $acknowledged = $false
        $txErrorSeen = $false
        $sendDeadline = [DateTime]::UtcNow.AddSeconds(2)
        while ([DateTime]::UtcNow -lt $sendDeadline) {
            $status = $xl.TryCanReceive($port, $rxEvent)
            if ($status -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) {
                Start-Sleep -Milliseconds 2
                continue
            }
            if ($status -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
                throw "Vector receive failed after transmit: $status"
            }
            if ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::TxOk) {
                $acknowledged = $true
                break
            }
            if ($rxEvent.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::TxError) {
                $txErrorSeen = $true
            }
        }

        if (-not $acknowledged) {
            if ($txErrorSeen) {
                Write-Warning 'The frame was not acknowledged by another CAN node.'
            }
            throw 'No TX confirmation was received. Check ESP bitrate, CAN-H/CAN-L/GND, and termination.'
        }
        Write-Host 'TX confirmed: another CAN node acknowledged the frame.'
        return
    }

    $dataLabel = if ($effectiveDataBitrate -eq 0) { 'classic CAN' } else { "CAN FD data $effectiveDataBitrate bit/s" }
    $monitorRole = if ($Mode -eq 'Monitor') { 'listen-only (does not ACK)' } else { 'active receiver (ACK enabled)' }
    Write-Host "VN1640A channel ${Channel}: $monitorRole, arbitration $ArbitrationBitrate bit/s, $dataLabel"
    Write-Host "Monitoring for $Seconds seconds. No application frames will be transmitted."

    $event = [Vector.XlApi.PniInternal.XlCanRxEvent]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $nextProgress = [DateTime]::UtcNow.AddSeconds(5)
    $frameCount = 0
    $matchingCount = 0
    $matchingFdCount = 0
    $matchingBrsCount = 0
    $matchingDlc15Count = 0
    $errorCount = 0
    $lastErrorCode = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($SummaryOnly -and [DateTime]::UtcNow -ge $nextProgress) {
            Write-Host "Progress: received $frameCount frames; ID 0x$('{0:X3}' -f $MonitorId) $matchingCount (FD $matchingFdCount, BRS $matchingBrsCount, DLC15 $matchingDlc15Count); receive errors $errorCount"
            $nextProgress = $nextProgress.AddSeconds(5)
        }
        $status = $xl.TryCanReceive($port, $event)
        if ($status -eq [Vector.XlApi.PniInternal.XlStatus]::ErrQueueIsEmpty) {
            Start-Sleep -Milliseconds 2
            continue
        }
        if ($status -ne [Vector.XlApi.PniInternal.XlStatus]::Success) {
            throw "Vector receive failed: $status"
        }

        if ($event.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::RxOk) {
            $frameCount++
            # Do not reuse the validated -CanId parameter variable. PowerShell
            # variable names are case-insensitive, and received extended IDs
            # legitimately exceed that transmit parameter's 11-bit range.
            $receivedCanId = $event.tagData_canRxOkMsg_canId
            $flags = $event.tagData_canRxOkMsg_msgFlags
            $dlc = $event.tagData_canRxOkMsg_dlc
            if ($MonitorId -eq 0 -or $receivedCanId -eq $MonitorId) {
                $matchingCount++
                if ($flags.ToString().Contains('Edl')) { $matchingFdCount++ }
                if ($flags.ToString().Contains('Brs')) { $matchingBrsCount++ }
                if ($dlc -eq 15) { $matchingDlc15Count++ }
            }
            if (-not $SummaryOnly) {
                Write-Host ('{0,12} us  ID 0x{1:X8}  DLC {2,2}  {3}' -f [uint64]($event.timeStamp / 1000), $receivedCanId, $dlc, $flags)
            }
        } elseif ($event.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::RxError) {
            $errorCount++
            $lastErrorCode = $event.tagData_canError_errorCode
            if ($errorCount -le 5) {
                Write-Warning "CAN receive error: $lastErrorCode"
            } elseif ($errorCount -eq 6) {
                Write-Warning 'Further CAN receive errors are suppressed; the final count will be shown.'
            }
        } elseif ($event.tag -eq [Vector.XlApi.PniInternal.XlCanEvTag]::ChipState) {
            Write-Host "CAN state: $($event.tagData_canChipState_busStatus), RX errors $($event.tagData_canChipState_rxErrorCounter), TX errors $($event.tagData_canChipState_txErrorCounter)"
        }
    }

    Write-Host "Done. Received frames: $frameCount; receive errors: $errorCount"
    Write-Host "ID 0x$('{0:X3}' -f $MonitorId): $matchingCount frames; FD $matchingFdCount; BRS $matchingBrsCount; DLC15 $matchingDlc15Count"
    if ($errorCount -gt 0) {
        Write-Host "Last CAN receive error: $lastErrorCode"
    }
}
finally {
    if ($activated) {
        $xl.DeactivateChannel($port, $channelMask)
    }
    if ($port -ne [Vector.XlApi.PniInternal.XlPortHandle]::Invalid) {
        $xl.ClosePort($port)
    }
}

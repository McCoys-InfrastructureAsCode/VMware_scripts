<#
.SYNOPSIS
    Automated root-cause helper for a host crash/reboot. Looks up the
    host's actual last boot time, auto-selects a window around it (unless
    you supply your own), pulls System/Application/Hyper-V-VMMS-Admin
    events across that window, flags common crash/reboot/hardware
    indicator events, and finds the largest gap in logging (which usually
    brackets the actual downtime).

.PARAMETER ComputerName
    FQDN or hostname of the target machine. Prompted for if not supplied.

.PARAMETER Credential
    PSCredential for the target machine. Prompted for interactively if not
    supplied (never pass a plaintext password on the command line).

.PARAMETER StartTime
    Start of the time window to query. If omitted, it is auto-selected as
    the host's LastBootUpTime minus -LookbackHours.

.PARAMETER EndTime
    End of the time window to query. If omitted, it is auto-selected as
    the host's LastBootUpTime plus -LookaheadMinutes.

.PARAMETER LookbackHours
    Hours before LastBootUpTime to include, for pre-crash context. Only
    used when -StartTime is not supplied. Default 4.

.PARAMETER LookaheadMinutes
    Minutes after LastBootUpTime to include, for post-boot context. Only
    used when -EndTime is not supplied. Default 30.

.PARAMETER LogName
    Event log(s) to query. Defaults to System, Application, and (if present
    on the target) the Hyper-V-VMMS-Admin log.

.PARAMETER OutputPath
    CSV path for the full, untruncated event dump. Defaults to
    .\crash-root-cause-<ComputerName>-<timestamp>.csv in the current
    directory.

.EXAMPLE
    .\Get-CrashRootCause.ps1 -ComputerName hvs044-01.mccoys.hq

.EXAMPLE
    .\Get-CrashRootCause.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-27 22:00:00" -EndTime "2026-08-28 07:00:00"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [datetime]$EndTime,

    [Parameter(Mandatory = $false)]
    [int]$LookbackHours = 4,

    [Parameter(Mandatory = $false)]
    [int]$LookaheadMinutes = 30,

    [Parameter(Mandatory = $false)]
    [string[]]$LogName = @('System', 'Application', 'Microsoft-Windows-Hyper-V-VMMS-Admin'),

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# Common crash/reboot indicator event IDs. Most providers don't reuse IDs,
# but a few small numbers (e.g. "1") are reused across unrelated providers,
# so those are matched as "Id + ProviderName" pairs instead of by Id alone.
$CrashIndicatorIds = @(
    1001,  # BugCheck (BSOD) - written on next boot
    41,    # Kernel-Power: system rebooted without clean shutdown
    6008,  # EventLog: previous shutdown was unexpected
    1074,  # User32/Kernel-General: shutdown/restart initiated (who/why)
    6005, 6006, 6013,  # Event log service start/stop, uptime
    55,    # Ntfs: volume corruption
    7031, 7034,  # Service Control Manager: service crashed unexpectedly
    5719,  # NETLOGON: lost secure channel to a domain controller
    11, 51, 153   # disk: disk/controller I/O errors, bad sectors
)

# WHEA-Logger IDs matched by (Id, ProviderName) since Id 1 collides with
# other providers (e.g. FilterManager) that have nothing to do with hardware.
$CrashIndicatorIdProviderPairs = @(
    @{ Id = 1; ProviderName = 'Microsoft-Windows-WHEA-Logger' },
    @{ Id = 17; ProviderName = 'Microsoft-Windows-WHEA-Logger' },
    @{ Id = 18; ProviderName = 'Microsoft-Windows-WHEA-Logger' },
    @{ Id = 19; ProviderName = 'Microsoft-Windows-WHEA-Logger' },
    @{ Id = 46; ProviderName = 'Microsoft-Windows-WHEA-Logger' },
    @{ Id = 47; ProviderName = 'Microsoft-Windows-WHEA-Logger' }
)

if (-not $ComputerName) {
    $ComputerName = Read-Host "Computer name (FQDN or hostname)"
}
if (-not $Credential) {
    $username = Read-Host "Username for $ComputerName (e.g. mccoys\yourname)"
    $securePassword = Read-Host "Password" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
}

Write-Host "Getting last boot time for $ComputerName ..." -ForegroundColor Cyan
$osInfo = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {
    Get-CimInstance Win32_OperatingSystem | Select-Object LastBootUpTime, CSName
}
Write-Host "Last boot time: $($osInfo.LastBootUpTime)" -ForegroundColor Green

if (-not $StartTime) {
    $StartTime = $osInfo.LastBootUpTime.AddHours(-$LookbackHours)
}
if (-not $EndTime) {
    $EndTime = $osInfo.LastBootUpTime.AddMinutes($LookaheadMinutes)
}
if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = ($ComputerName -replace '[^\w\.-]', '_')
    $OutputPath = ".\crash-root-cause-$safeName-$stamp.csv"
}

Write-Host "Querying $($LogName -join ', ') on $ComputerName from $StartTime to $EndTime ..." -ForegroundColor Cyan

$events = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {
    $logNames = @($using:LogName)
    $start = $using:StartTime
    $end = $using:EndTime
    foreach ($log in $logNames) {
        try {
            Get-WinEvent -FilterHashtable @{
                LogName   = [string]$log
                StartTime = $start
                EndTime   = $end
            } -ErrorAction Stop
        }
        catch [Exception] {
            if ($_.Exception.Message -notmatch 'No events were found|no such log|does not exist') { throw }
        }
    }
} |
    Sort-Object TimeCreated |
    Select-Object TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message,
        @{N = 'CrashIndicator'; E = {
            $evt = $_
            [bool](($evt.Id -in $CrashIndicatorIds) -or
                ($CrashIndicatorIdProviderPairs | Where-Object { $_.Id -eq $evt.Id -and $_.ProviderName -eq $evt.ProviderName }))
        } }

if (-not $events) {
    Write-Host "No events found in that window." -ForegroundColor Yellow
    return
}

$events | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Full event dump (all logs, untruncated) written to $OutputPath" -ForegroundColor Green

# --- Find the largest gap in logging (usually brackets actual downtime) ---
$largestGap = $null
for ($i = 1; $i -lt $events.Count; $i++) {
    $prev = $events[$i - 1]
    $curr = $events[$i]
    $duration = [datetime]$curr.TimeCreated - [datetime]$prev.TimeCreated
    if (-not $largestGap -or $duration -gt $largestGap.Duration) {
        $largestGap = [PSCustomObject]@{
            Before   = $prev
            After    = $curr
            Duration = $duration
        }
    }
}

# EventLog 6008 records the OS's own account of when the previous shutdown
# happened, e.g. "The previous system shutdown at 1:35:15 AM on 8/28/2026
# was unexpected." This is more reliable than gap detection, since gap
# detection only sees gaps *inside* the queried window -- if the actual
# crash happened before the window start, gap detection will miss it
# entirely and this is the only way to learn the real crash time.
$reportedShutdownTime = $null
$shutdown6008 = $events | Where-Object { $_.Id -eq 6008 -and $_.ProviderName -eq 'EventLog' } | Select-Object -First 1
if ($shutdown6008) {
    $cleanMessage = $shutdown6008.Message
    foreach ($invisibleChar in @([char]0x200E, [char]0x200F)) {
        $cleanMessage = $cleanMessage.Replace([string]$invisibleChar, '')
    }
    if ($cleanMessage -match 'shutdown at\s+(?<time>[\d:]+\s*[AP]M)\s+on\s+(?<date>[\d/]+)') {
        try { $reportedShutdownTime = [datetime]"$($Matches.date) $($Matches.time)" } catch {}
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Host:            $ComputerName"
Write-Host "Last boot time:  $($osInfo.LastBootUpTime)"
Write-Host "Window queried:  $StartTime to $EndTime"

if ($reportedShutdownTime) {
    $downtime = $osInfo.LastBootUpTime - $reportedShutdownTime
    Write-Host "Windows-reported previous unexpected shutdown: $reportedShutdownTime (downtime until reboot: $([math]::Round($downtime.TotalMinutes, 1)) min)" -ForegroundColor Red
    if ($reportedShutdownTime -lt $StartTime) {
        Write-Host "  NOTE: this is earlier than the queried window start ($StartTime) -- re-run with a larger -LookbackHours (or explicit -StartTime) to see events leading up to it." -ForegroundColor Yellow
    }
}

if ($largestGap -and $largestGap.Duration -gt (New-TimeSpan -Minutes 1)) {
    Write-Host "Largest logging gap in queried window: $($largestGap.Before.TimeCreated) -> $($largestGap.After.TimeCreated) ($([math]::Round($largestGap.Duration.TotalMinutes, 1)) min)" -ForegroundColor Yellow
    Write-Host "  Last event before gap: [$($largestGap.Before.LogName)/$($largestGap.Before.Id)] $($largestGap.Before.ProviderName)"
    Write-Host "  First event after gap: [$($largestGap.After.LogName)/$($largestGap.After.Id)] $($largestGap.After.ProviderName)"
}
else {
    Write-Host "No significant logging gap (>1 min) found in this window." -ForegroundColor Yellow
}

$flagged = $events | Where-Object { $_.CrashIndicator }
if ($flagged) {
    Write-Host "`n=== Possible crash/reboot/hardware indicators ===" -ForegroundColor Red
    $flagged | Format-Table TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message -Wrap
}
else {
    Write-Host "`nNo classic crash/reboot/hardware indicator event IDs found in this window." -ForegroundColor Yellow
}

Write-Host "`n=== All events ===" -ForegroundColor Cyan
$events | Format-Table TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message -Wrap

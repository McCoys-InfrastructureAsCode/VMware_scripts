<#
.SYNOPSIS
    Pulls Windows event log entries for a host within a given time window,
    useful for investigating a crash/reboot. Queries System, Application,
    and the Hyper-V-VMMS-Admin log by default, and flags common
    crash/reboot indicator event IDs -- including hardware-related ones
    (WHEA-Logger, disk).

.PARAMETER ComputerName
    FQDN or hostname of the target machine. Prompted for if not supplied.

.PARAMETER StartTime
    Start of the time window to query (DateTime). Defaults to 12 hours before
    the current time if not supplied.

.PARAMETER EndTime
    End of the time window to query (DateTime). Defaults to the current time
    if not supplied.

.PARAMETER Credential
    PSCredential for the target machine. Prompted for interactively if not
    supplied (never pass a plaintext password on the command line).

.PARAMETER LogName
    Event log(s) to query. Defaults to System, Application, and (if present
    on the target) the Hyper-V-VMMS-Admin log. Note: hardware error sources
    like WHEA-Logger and the "disk" provider already log into the System
    log, so they don't need a separate LogName -- their event IDs are
    included in the crash-indicator flagging instead.

.PARAMETER OutputPath
    CSV path for the full, untruncated event dump. Defaults to
    .\crash-events-<ComputerName>-<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-CrashWindowEvents.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-27 22:00:00" -EndTime "2026-08-28 07:00:00"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [datetime]$EndTime,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

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
if (-not $EndTime) {
    $EndTime = Get-Date
}
if (-not $StartTime) {
    $StartTime = $EndTime.AddHours(-12)
}
if (-not $Credential) {
    $username = Read-Host "Username for $ComputerName (e.g. mccoys\yourname)"
    $securePassword = Read-Host "Password" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
}
if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = ($ComputerName -replace '[^\w\.-]', '_')
    $OutputPath = ".\crash-events-$safeName-$stamp.csv"
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

Write-Host "`n=== All events ===" -ForegroundColor Cyan
$events | Format-Table TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message -Wrap

$flagged = $events | Where-Object { $_.CrashIndicator }
if ($flagged) {
    Write-Host "`n=== Possible crash/reboot indicators ===" -ForegroundColor Red
    $flagged | Format-Table TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message -Wrap
}
else {
    Write-Host "`nNo classic crash/reboot indicator event IDs (41, 1074, 6008, 1001, etc.) found in this window." -ForegroundColor Yellow
}

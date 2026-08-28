<#
.SYNOPSIS
    Pulls Windows event log entries for a host within a given time window,
    useful for investigating a crash/reboot. Queries System and Application
    logs by default and flags common crash/reboot indicator event IDs.

.PARAMETER ComputerName
    FQDN or hostname of the target machine. Prompted for if not supplied.

.PARAMETER StartTime
    Start of the time window to query (DateTime). Prompted for if not supplied.

.PARAMETER EndTime
    End of the time window to query (DateTime). Prompted for if not supplied.

.PARAMETER Credential
    PSCredential for the target machine. Prompted for interactively if not
    supplied (never pass a plaintext password on the command line).

.PARAMETER LogName
    Event log(s) to query. Defaults to System and Application.

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
    [string[]]$LogName = @('System', 'Application'),

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# Common crash/reboot indicator event IDs (System log unless noted).
$CrashIndicatorIds = @(
    1001,  # BugCheck (BSOD) - written on next boot
    41,    # Kernel-Power: system rebooted without clean shutdown
    6008,  # EventLog: previous shutdown was unexpected
    1074,  # User32/Kernel-General: shutdown/restart initiated (who/why)
    6005, 6006, 6013,  # Event log service start/stop, uptime
    55,    # Ntfs: volume corruption
    7031, 7034,  # Service Control Manager: service crashed unexpectedly
    5719   # NETLOGON: lost secure channel to a domain controller
)

if (-not $ComputerName) {
    $ComputerName = Read-Host "Computer name (FQDN or hostname)"
}
if (-not $StartTime) {
    $StartTime = Read-Host "Start time (e.g. 2026-08-28 01:00:00)"
}
if (-not $EndTime) {
    $EndTime = Read-Host "End time (e.g. 2026-08-28 04:00:00)"
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
            if ($_.Exception.Message -notmatch 'No events were found') { throw }
        }
    }
} |
    Sort-Object TimeCreated |
    Select-Object TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message,
        @{N = 'CrashIndicator'; E = { $_.Id -in $CrashIndicatorIds } }

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

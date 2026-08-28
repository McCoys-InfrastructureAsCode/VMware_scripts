<#
.SYNOPSIS
    Pulls Windows System event log entries for a host within a given time
    window, useful for investigating a crash/reboot.

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
    Event log to query. Defaults to 'System'.

.EXAMPLE
    .\Get-CrashWindowEvents.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-28 01:00:00" -EndTime "2026-08-28 04:00:00"
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
    [string]$LogName = 'System'
)

$ErrorActionPreference = 'Stop'

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

Get-WinEvent -ComputerName $ComputerName -Credential $Credential -FilterHashtable @{
    LogName   = $LogName
    StartTime = $StartTime
    EndTime   = $EndTime
} | Sort-Object TimeCreated | Format-Table TimeCreated, Id, ProviderName, LevelDisplayName, Message -Wrap

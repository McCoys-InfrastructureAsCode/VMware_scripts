<#
.SYNOPSIS
    Inventories ESXi host hardware (vendor/model/CPU/memory) across a vCenter
    and summarizes counts by manufacturer and by manufacturer+model.

.PARAMETER VCenter
    FQDN or IP of the vCenter Server. Prompted for if not supplied.

.PARAMETER Credential
    PSCredential for vCenter. Prompted for interactively if not supplied
    (never pass a plaintext password on the command line).

.PARAMETER OutputPath
    CSV path for the full per-host inventory. Defaults to
    .\vsphere-hardware-inventory-<timestamp>.csv in the current directory.

.PARAMETER AllowInvalidCert
    Allow connecting to vCenters with self-signed / untrusted certificates.
    Off by default; pass this switch explicitly if your vCenter uses one.

.EXAMPLE
    .\Get-VSphereHardwareInventory.ps1 -VCenter vcenter.corp.local

.EXAMPLE
    .\Get-VSphereHardwareInventory.ps1 -VCenter vcenter.corp.local -AllowInvalidCert
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VCenter,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [switch]$AllowInvalidCert
)

$ErrorActionPreference = 'Stop'

# --- Ensure PowerCLI is available -------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    Write-Host "VMware.PowerCLI module not found." -ForegroundColor Yellow
    $install = Read-Host "Install it now for the current user? (y/n)"
    if ($install -eq 'y') {
        Install-Module VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber
    }
    else {
        Write-Error "VMware.PowerCLI is required. Install with: Install-Module VMware.PowerCLI -Scope CurrentUser"
        exit 1
    }
}

Import-Module VMware.PowerCLI -ErrorAction Stop

if ($AllowInvalidCert) {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
}
Set-PowerCLIConfiguration -ParticipateInCeip $false -Confirm:$false -Scope Session | Out-Null

# --- Gather connection details ------------------------------------------------------
if (-not $VCenter) {
    $VCenter = Read-Host "vCenter Server (FQDN or IP)"
}
if (-not $Credential) {
    $Credential = Get-Credential -Message "Credentials for $VCenter"
}
if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = ".\vsphere-hardware-inventory-$stamp.csv"
}

# --- Connect -------------------------------------------------------------------------
Write-Host "Connecting to $VCenter ..." -ForegroundColor Cyan
Connect-VIServer -Server $VCenter -Credential $Credential | Out-Null

try {
    # --- Pull per-host hardware info --------------------------------------------
    Write-Host "Querying ESXi hosts ..." -ForegroundColor Cyan

    $inventory = Get-VMHost | ForEach-Object {
        $hv = $_
        $hw = $hv.ExtensionData.Hardware
        [PSCustomObject]@{
            Name         = $hv.Name
            Cluster      = ($hv.Parent).Name
            Manufacturer = $hv.Manufacturer
            Model        = $hv.Model
            CpuModel     = $hw.CpuPkg[0].Description
            CpuSockets   = $hw.CpuInfo.NumCpuPackages
            CpuCores     = $hw.CpuInfo.NumCpuCores
            MemoryGB     = [math]::Round($hv.MemoryTotalGB, 1)
            EsxiVersion  = $hv.Version
            EsxiBuild    = $hv.Build
            ConnectionState = $hv.ConnectionState
        }
    }

    $inventory | Sort-Object Manufacturer, Model, Name | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Host "Full inventory written to $OutputPath" -ForegroundColor Green

    # --- Summaries ----------------------------------------------------------------
    Write-Host "`n=== Host count by Manufacturer ===" -ForegroundColor Cyan
    $inventory | Group-Object Manufacturer |
        Select-Object @{N='Manufacturer';E={$_.Name}}, Count |
        Sort-Object Count -Descending |
        Format-Table -AutoSize

    Write-Host "`n=== Host count by Manufacturer + Model ===" -ForegroundColor Cyan
    $inventory | Group-Object Manufacturer, Model |
        Select-Object @{N='Manufacturer/Model';E={$_.Name}}, Count |
        Sort-Object Count -Descending |
        Format-Table -AutoSize

    Write-Host "`n=== Total CPU cores / Memory by Manufacturer ===" -ForegroundColor Cyan
    $inventory | Group-Object Manufacturer | ForEach-Object {
        [PSCustomObject]@{
            Manufacturer  = $_.Name
            Hosts         = $_.Count
            TotalCores    = ($_.Group | Measure-Object -Property CpuCores -Sum).Sum
            TotalMemoryGB = [math]::Round((($_.Group | Measure-Object -Property MemoryGB -Sum).Sum), 1)
        }
    } | Sort-Object Hosts -Descending | Format-Table -AutoSize
}
finally {
    Disconnect-VIServer -Server $VCenter -Confirm:$false
    Write-Host "Disconnected from $VCenter" -ForegroundColor Cyan
}
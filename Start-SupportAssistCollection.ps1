<#
.SYNOPSIS
    Triggers a Dell SupportAssist Collection on an iDRAC9 over Redfish and
    waits for it to complete, so you don't have to babysit the web UI for
    the several minutes a collection takes.

.DESCRIPTION
    SupportAssist Collection bundles hardware inventory, the Lifecycle
    Log, System Event Log, TTY log, and (optionally) OS-level data into a
    single .zip -- useful alongside Get-CrashDumpAnalysis.ps1 and
    get_idrac_memory_errors.py as a broader cross-check when investigating
    a crash.

    Without a network share configured, the finished bundle is stored on
    the iDRAC's own internal storage. Dell doesn't expose a documented,
    stable Redfish/racadm path to pull a locally-stored bundle directly --
    only to push it to a CIFS/NFS/HTTP(S) share -- so this script stops at
    "collection complete" and tells you where to download it manually
    (Maintenance > SupportAssist > SupportAssist Collections in the web
    UI). If you set up a share later, extend the $collectBody hashtable
    below with ShareType/IPAddress/ShareName/Username/Password to push the
    export there directly instead.

    Exact Redfish action names/payload fields for SupportAssist have
    shifted a bit across iDRAC9 firmware revisions. If a call below 404s,
    this script fetches DellLCService's actual advertised Actions and
    prints them, so you can see what this firmware really calls things
    rather than guessing blind.

.PARAMETER IDRAC
    iDRAC hostname or IP. Prompted for if not supplied.

.PARAMETER Credential
    PSCredential for the iDRAC. Prompted for interactively if not supplied
    (never pass a plaintext password on the command line).

.PARAMETER Insecure
    Skip TLS certificate verification (common for iDRACs with self-signed
    certs).

.PARAMETER DataSelector
    Which data types to include. Defaults to HWData, TTYLogData,
    TelemetryReports (pure hardware/firmware data, no OS credentials
    needed). Add 'OSAppData' for OS-level data, but note that may require
    additional OS credential fields in the collect request that this
    script doesn't currently set.

.PARAMETER PollIntervalSec
    Seconds between job status checks. Default 15.

.PARAMETER MaxWaitMinutes
    Give up waiting after this many minutes (the collection itself keeps
    running on the iDRAC regardless of whether this script is watching).
    Default 30.

.EXAMPLE
    .\Start-SupportAssistCollection.ps1 -IDRAC 10.200.44.133 -Insecure
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$IDRAC,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$Insecure,

    [Parameter(Mandatory = $false)]
    [string[]]$DataSelector = @('HWData', 'TTYLogData', 'TelemetryReports'),

    [Parameter(Mandatory = $false)]
    [int]$PollIntervalSec = 15,

    [Parameter(Mandatory = $false)]
    [int]$MaxWaitMinutes = 30
)

$ErrorActionPreference = 'Stop'

if (-not $IDRAC) {
    $IDRAC = Read-Host "iDRAC hostname or IP"
}
if (-not $Credential) {
    $username = Read-Host "Username for $IDRAC (default: root)"
    if (-not $username) { $username = 'root' }
    $securePassword = Read-Host "Password" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

$prevCertCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$prevCertPolicy = [Net.ServicePointManager]::CertificatePolicy
if ($Insecure) {
    # ServerCertificateValidationCallback alone doesn't reliably suppress
    # self-signed-cert handshake failures in Windows PowerShell (.NET
    # Framework) -- surfaces as a generic "underlying connection was
    # closed: An unexpected error occurred on a send". The older
    # ICertificatePolicy override is the more reliable bypass here.
    if (-not ('TrustAllCertsPolicy' -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$BaseUrl = "https://$IDRAC"

function Invoke-IDrac {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        $Body
    )
    $params = @{
        Uri             = if ($Path -match '^https?://') { $Path } else { "$BaseUrl$Path" }
        Method          = $Method
        Credential      = $Credential
        ContentType     = 'application/json'
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 6)
    }
    try {
        return Invoke-WebRequest @params
    }
    catch {
        $detail = $_.ErrorDetails.Message
        if ($detail) {
            throw "iDRAC request to $Path failed: $($_.Exception.Message) -- $detail"
        }
        throw
    }
}

function Get-DellLCServicePath {
    $candidate = "/redfish/v1/Dell/Systems/System.Embedded.1/DellLCService"
    try {
        Invoke-IDrac -Method Get -Path $candidate | Out-Null
        return $candidate
    }
    catch {
        $systems = (Invoke-IDrac -Method Get -Path "/redfish/v1/Systems").Content | ConvertFrom-Json
        $systemId = ($systems.Members[0].'@odata.id').TrimEnd('/').Split('/')[-1]
        return "/redfish/v1/Dell/Systems/$systemId/DellLCService"
    }
}

function Show-AvailableActions {
    param([string]$ServicePath)
    try {
        $svc = (Invoke-IDrac -Method Get -Path $ServicePath).Content | ConvertFrom-Json
        if ($svc.Actions) {
            $names = $svc.Actions.PSObject.Properties.Name
            Write-Host "Actions advertised by $ServicePath on this firmware:" -ForegroundColor Yellow
            $names | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }
    }
    catch {
        Write-Host "Could not re-fetch $ServicePath to list its actions: $_" -ForegroundColor Yellow
    }
}

try {
    Write-Host "Connecting to $IDRAC ..." -ForegroundColor Cyan
    $lcServicePath = Get-DellLCServicePath
    Write-Host "Using DellLCService at $lcServicePath" -ForegroundColor Cyan

    try {
        Write-Host "Checking SupportAssist EULA status ..." -ForegroundColor Cyan
        $eulaStatus = (Invoke-IDrac -Method Post -Path "$lcServicePath/Actions/DellLCService.SupportAssistGetEULAStatus" -Body @{}).Content | ConvertFrom-Json
        if ($eulaStatus.EULAStatus -ne 'Accepted') {
            Write-Host "Accepting SupportAssist EULA ..." -ForegroundColor Cyan
            Invoke-IDrac -Method Post -Path "$lcServicePath/Actions/DellLCService.SupportAssistAcceptEULA" -Body @{} | Out-Null
        }
    }
    catch {
        Write-Host "EULA check/accept failed: $_" -ForegroundColor Red
        Show-AvailableActions -ServicePath $lcServicePath
        throw
    }

    Write-Host "Starting SupportAssist Collection (data: $($DataSelector -join ', ')) ..." -ForegroundColor Cyan
    $collectBody = @{
        ShareType           = 'Local'
        DataSelectorArrayIn = $DataSelector
    }
    try {
        $collectResponse = Invoke-IDrac -Method Post -Path "$lcServicePath/Actions/DellLCService.SupportAssistCollection" -Body $collectBody
    }
    catch {
        Write-Host "SupportAssistCollection call failed: $_" -ForegroundColor Red
        Show-AvailableActions -ServicePath $lcServicePath
        throw
    }

    $jobLocation = $collectResponse.Headers['Location']
    if ($jobLocation -is [array]) { $jobLocation = $jobLocation[0] }
    if (-not $jobLocation) {
        throw "iDRAC didn't return a job location for the collection request (HTTP $($collectResponse.StatusCode)). Check $lcServicePath / the web UI's Job Queue manually."
    }
    Write-Host "Collection job started: $jobLocation" -ForegroundColor Green

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    $state = $null
    do {
        Start-Sleep -Seconds $PollIntervalSec
        $job = (Invoke-IDrac -Method Get -Path $jobLocation).Content | ConvertFrom-Json
        $state = if ($job.JobState) { $job.JobState } else { $job.TaskState }
        $pct = $job.PercentComplete
        Write-Host "  Job state: $state ($pct%)" -ForegroundColor Cyan
    } while ($state -notin @('Completed', 'CompletedWithErrors', 'Failed', 'Exception') -and (Get-Date) -lt $deadline)

    if ($state -notin @('Completed', 'CompletedWithErrors')) {
        throw "Collection job did not reach a completed state (last seen: $state). It may still be running on the iDRAC -- check $jobLocation or the web UI's Job Queue."
    }

    Write-Host "`nCollection finished (state: $state)." -ForegroundColor Green
    Write-Host "No network share was configured, so the bundle is stored on the iDRAC's own internal storage." -ForegroundColor Yellow
    Write-Host "Download it manually: https://$IDRAC/ -> Maintenance -> SupportAssist -> SupportAssist Collections" -ForegroundColor Yellow
}
finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCertCallback
    [Net.ServicePointManager]::CertificatePolicy = $prevCertPolicy
}

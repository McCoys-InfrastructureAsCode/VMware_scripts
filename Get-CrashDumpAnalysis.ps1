<#
.SYNOPSIS
    Pulls a memory dump (default C:\Windows\MEMORY.DMP) from a remote host
    over WinRM and runs an automated "!analyze -v" against it with cdb.exe,
    to identify the process/driver that actually caused a bugcheck (e.g.
    the CRITICAL_PROCESS_DIED culprit behind a 0xEF).

.PARAMETER ComputerName
    FQDN or hostname of the target machine. Prompted for if not supplied.

.PARAMETER Credential
    PSCredential for the target machine. Prompted for interactively if not
    supplied (never pass a plaintext password on the command line).

.PARAMETER DumpPath
    Path to the dump file on the remote host. Defaults to
    C:\Windows\MEMORY.DMP (the default location for kernel/complete dumps).
    For per-crash minidumps, point this at a specific file under
    C:\Windows\Minidump\ instead.

.PARAMETER LocalDumpDir
    Local directory the dump is copied into before analysis. Defaults to
    .\dumps. Each run copies to its own timestamped filename, so repeat
    runs (including against the same host) don't collide or overwrite.

.PARAMETER CdbPath
    Path to cdb.exe. Auto-detected from common "Debugging Tools for
    Windows" / Windows SDK install locations and PATH if not supplied.

.PARAMETER SymbolCachePath
    Local folder used to cache downloaded symbols across runs, so repeat
    analyses (even of different dumps) don't re-download every time.
    Defaults to .\symbols.

.PARAMETER SymbolServer
    Symbol server URL. Defaults to Microsoft's public symbol server.

.PARAMETER OutputPath
    Path for the full, untruncated !analyze -v text output. Defaults to
    .\crash-dump-analysis-<ComputerName>-<timestamp>.txt in the current
    directory.

.PARAMETER KeepLocalDump
    Keep the copied .dmp file after analysis. Off by default -- dumps can
    be large, so they're deleted once analysis completes unless you pass
    this switch (e.g. to re-run cdb manually or inspect it further).

.EXAMPLE
    .\Get-CrashDumpAnalysis.ps1 -ComputerName hvs044-01.mccoys.hq

.EXAMPLE
    .\Get-CrashDumpAnalysis.ps1 -ComputerName hvs044-01.mccoys.hq -DumpPath 'C:\Windows\Minidump\082826-12345-01.dmp' -KeepLocalDump
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$DumpPath = 'C:\Windows\MEMORY.DMP',

    [Parameter(Mandatory = $false)]
    [string]$LocalDumpDir = '.\dumps',

    [Parameter(Mandatory = $false)]
    [string]$CdbPath,

    [Parameter(Mandatory = $false)]
    [string]$SymbolCachePath = '.\symbols',

    [Parameter(Mandatory = $false)]
    [string]$SymbolServer = 'https://msdl.microsoft.com/download/symbols',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$KeepLocalDump
)

$ErrorActionPreference = 'Stop'

function Find-CdbPath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
        "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x86\cdb.exe",
        "${env:ProgramFiles(x86)}\Debugging Tools for Windows (x64)\cdb.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    $onPath = Get-Command cdb.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

if (-not $ComputerName) {
    $ComputerName = Read-Host "Computer name (FQDN or hostname)"
}
if (-not $Credential) {
    $username = Read-Host "Username for $ComputerName (e.g. mccoys\yourname)"
    $securePassword = Read-Host "Password" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
}
if (-not $CdbPath) {
    $CdbPath = Find-CdbPath
}
if (-not $CdbPath) {
    throw "cdb.exe not found. Install 'Debugging Tools for Windows' (part of the Windows SDK -- you can select just that component in the SDK installer), then re-run, or pass -CdbPath explicitly."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeName = ($ComputerName -replace '[^\w\.-]', '_')

if (-not $OutputPath) {
    $OutputPath = ".\crash-dump-analysis-$safeName-$stamp.txt"
}

New-Item -ItemType Directory -Force -Path $LocalDumpDir | Out-Null
New-Item -ItemType Directory -Force -Path $SymbolCachePath | Out-Null
$localDumpPath = Join-Path $LocalDumpDir "$safeName-$stamp$([IO.Path]::GetExtension($DumpPath))"

Write-Host "Connecting to $ComputerName ..." -ForegroundColor Cyan
$session = New-PSSession -ComputerName $ComputerName -Credential $Credential

try {
    $remoteInfo = Invoke-Command -Session $session -ScriptBlock {
        param($path)
        if (Test-Path -LiteralPath $path) {
            Get-Item -LiteralPath $path | Select-Object Length, LastWriteTime
        }
    } -ArgumentList $DumpPath

    if (-not $remoteInfo) {
        throw "Dump file $DumpPath not found on $ComputerName. It may have already been cleaned up, or the crash produced a minidump under C:\Windows\Minidump\ instead -- pass -DumpPath to point at that file."
    }

    $sizeMB = [math]::Round($remoteInfo.Length / 1MB, 1)
    Write-Host "Found $DumpPath ($sizeMB MB, last written $($remoteInfo.LastWriteTime)). Copying to $localDumpPath ..." -ForegroundColor Cyan

    $copyElapsed = Measure-Command {
        Copy-Item -FromSession $session -Path $DumpPath -Destination $localDumpPath
    }
    Write-Host "Copy finished in $([math]::Round($copyElapsed.TotalSeconds, 1))s." -ForegroundColor Green
}
finally {
    Remove-PSSession $session
}

Write-Host "Running !analyze -v (symbols cached under $SymbolCachePath, first run per bugcheck may be slow) ..." -ForegroundColor Cyan

$prevSymPath = $env:_NT_SYMBOL_PATH
$env:_NT_SYMBOL_PATH = "srv*$SymbolCachePath*$SymbolServer"
try {
    $stdoutTemp = [IO.Path]::GetTempFileName()
    $stderrTemp = [IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath $CdbPath `
        -ArgumentList @('-z', "`"$localDumpPath`"", '-c', '"!analyze -v;q"') `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutTemp -RedirectStandardError $stderrTemp
    $analysis = Get-Content -Raw $stdoutTemp -ErrorAction SilentlyContinue
    Remove-Item $stdoutTemp, $stderrTemp -ErrorAction SilentlyContinue
}
finally {
    $env:_NT_SYMBOL_PATH = $prevSymPath
}

if ($proc.ExitCode -ne 0) {
    Write-Host "cdb.exe exited with code $($proc.ExitCode) -- output may still be useful below." -ForegroundColor Yellow
}

$analysis | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host "Full analyze -v output written to $OutputPath" -ForegroundColor Green

$highlights = $analysis -split "`r?`n" | Where-Object { $_ -match '^[A-Z][A-Z0-9_]*:\s*\S' }
if ($highlights) {
    Write-Host "`n=== Bugcheck analysis highlights ===" -ForegroundColor Red
    $highlights | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host "`nNo bucketed analysis fields found -- check $OutputPath directly (symbols may be missing/incomplete)." -ForegroundColor Yellow
}

if ($KeepLocalDump) {
    Write-Host "`nLocal dump copy kept at $localDumpPath" -ForegroundColor Cyan
}
else {
    Remove-Item -LiteralPath $localDumpPath -ErrorAction SilentlyContinue
    Write-Host "`nLocal dump copy removed ($localDumpPath). Pass -KeepLocalDump to retain it." -ForegroundColor Cyan
}

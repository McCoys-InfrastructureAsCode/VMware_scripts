# get_vsphere_inventory

Scripts for pulling inventory and troubleshooting data from vSphere/Windows
infrastructure.

- [Get-VSphereHardwareInventory.ps1](#get-vspherehardwareinventoryps1) --
  inventories ESXi host hardware across a vCenter.
- [Get-CrashWindowEvents.ps1](#get-crashwindoweventsps1) -- pulls Windows
  event log entries for a host in a time window, for crash/reboot
  investigation.

## Execution policy

If running a script fails with `running scripts is disabled on this
system`, either bypass it for one run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-CrashWindowEvents.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-27 22:00:00" -EndTime "2026-08-28 07:00:00"
```

or set it for your current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Get-VSphereHardwareInventory.ps1

Inventories ESXi host hardware (vendor, model, CPU, memory) across a vCenter
Server and prints summary counts by manufacturer and by manufacturer+model.

### Prerequisites

- PowerShell 5.1+ (Windows PowerShell or PowerShell 7)
- [VMware PowerCLI](https://developer.vmware.com/powercli) module
  - The script checks for it on startup and offers to install it for the
    current user if missing:
    ```powershell
    Install-Module VMware.PowerCLI -Scope CurrentUser
    ```
- Network access to the target vCenter Server and an account with read
  access to hosts/clusters

### Usage

Run with no arguments and answer the prompts:

```powershell
.\Get-VsphereHardwareInventory.ps1
```

Or supply the vCenter up front (you'll still be prompted for credentials):

```powershell
.\Get-VsphereHardwareInventory.ps1 -VCenter vcenter.corp.local
```

If your vCenter uses a self-signed/untrusted certificate:

```powershell
.\Get-VsphereHardwareInventory.ps1 -VCenter vcenter.corp.local -AllowInvalidCert
```

Pass credentials non-interactively (e.g. from a script or scheduled task)
using a `PSCredential` object -- never pass a plaintext password on the
command line:

```powershell
$cred = Get-Credential
.\Get-VsphereHardwareInventory.ps1 -VCenter vcenter.corp.local -Credential $cred
```

Choose a specific output path for the CSV:

```powershell
.\Get-VsphereHardwareInventory.ps1 -VCenter vcenter.corp.local -OutputPath C:\reports\hosts.csv
```

### Parameters

| Parameter           | Required | Description |
|----------------------|----------|-------------|
| `-VCenter`           | No       | FQDN or IP of the vCenter Server. Prompted for if omitted. |
| `-Credential`        | No       | `PSCredential` for vCenter. Prompted for interactively if omitted. |
| `-OutputPath`        | No       | CSV path for the full per-host inventory. Defaults to `.\vsphere-hardware-inventory-<timestamp>.csv` in the current directory. |
| `-AllowInvalidCert`  | No       | Switch to allow connecting to vCenters with self-signed/untrusted certificates. Off by default. |

### Output

- A CSV file with one row per ESXi host, including name, cluster,
  manufacturer, model, CPU model/sockets/cores, memory (GB), ESXi
  version/build, and connection state.
- Console summary tables:
  - Host count by manufacturer
  - Host count by manufacturer + model
  - Total CPU cores and memory by manufacturer

The script disconnects from vCenter automatically when it finishes (or if
an error occurs).

## Get-CrashWindowEvents.ps1

Pulls Windows event log entries for a host within a given time window --
useful for correlating what happened around a crash or unexpected reboot.
Queries the System and Application logs by default, runs remotely over
WinRM, and flags common crash/reboot indicator event IDs (Kernel-Power 41,
unexpected shutdown 6008, BugCheck 1001, shutdown-initiated 1074, service
crashes 7031/7034, NTFS corruption 55, lost domain secure channel 5719,
etc.) in a separate highlighted section.

### Prerequisites

- PowerShell 5.1+
- WinRM/PowerShell remoting reachable on the target host (this script uses
  `Invoke-Command`, not legacy RPC event-log remoting, so it only needs
  port 5985/5986 open -- not RPC port 135 + dynamic ports).
  Quick check: `Test-WSMan <ComputerName>`
- An account with rights to read event logs and to PowerShell-remote into
  the target host

### Usage

Run with no arguments and answer the prompts:

```powershell
.\Get-CrashWindowEvents.ps1
```

Or supply everything up front (you'll still be prompted for credentials):

```powershell
.\Get-CrashWindowEvents.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-27 22:00:00" -EndTime "2026-08-28 07:00:00"
```

Query a specific log only:

```powershell
.\Get-CrashWindowEvents.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-28 01:00:00" -EndTime "2026-08-28 04:00:00" -LogName System
```

Pass credentials non-interactively -- never pass a plaintext password on
the command line:

```powershell
$cred = Get-Credential
.\Get-CrashWindowEvents.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-28 01:00:00" -EndTime "2026-08-28 04:00:00" -Credential $cred
```

### Parameters

| Parameter        | Required | Description |
|-------------------|----------|-------------|
| `-ComputerName`   | No       | FQDN or hostname of the target machine. Prompted for if omitted. |
| `-StartTime`      | No       | Start of the time window to query. Prompted for if omitted. |
| `-EndTime`        | No       | End of the time window to query. Prompted for if omitted. |
| `-Credential`     | No       | `PSCredential` for the target machine. Prompted for (username/password, console-based) if omitted. |
| `-LogName`        | No       | Event log(s) to query. Defaults to `System` and `Application`. |
| `-OutputPath`     | No       | CSV path for the full, untruncated event dump. Defaults to `.\crash-events-<ComputerName>-<timestamp>.csv` in the current directory. |

### Output

- Console table of all events found in the window, plus a highlighted
  "Possible crash/reboot indicators" table for known crash-related event
  IDs.
- A CSV file with the full, untruncated event set (all fields, all logs)
  for further review.

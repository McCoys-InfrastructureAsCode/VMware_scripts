# get_vsphere_inventory

Scripts for pulling crash/reboot troubleshooting data from Windows hosts.

- [Get-CrashWindowEvents.ps1](#get-crashwindoweventsps1) -- pulls Windows
  event log entries for a host in a time window, for crash/reboot
  investigation.
- [Get-CrashRootCause.ps1](#get-crashrootcauseps1) -- automated root-cause
  drill-down: finds the host's actual last boot time, auto-selects a
  window around it, and detects the logging gap that likely brackets the
  actual downtime.

Typical crash/reboot workflow: run `Get-CrashWindowEvents.ps1` first for a
broad look at what happened, then `Get-CrashRootCause.ps1` to narrow in on
the likely cause and downtime window -- both run over WinRM, so you don't
need iDRAC or vSphere console access for this kind of triage.

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

## Get-CrashWindowEvents.ps1

Pulls Windows event log entries for a host within a given time window --
useful for correlating what happened around a crash or unexpected reboot.
Queries the System, Application, and Hyper-V-VMMS-Admin logs by default,
runs remotely over WinRM, and flags common crash/reboot indicator event
IDs in a separate highlighted section, including:

- Kernel-Power 41 (unclean reboot), unexpected shutdown 6008,
  BugCheck 1001, shutdown-initiated 1074
- Service crashes 7031/7034, NTFS corruption 55, lost domain secure
  channel 5719
- Hardware errors: WHEA-Logger 1/17/18/19/46/47 (CPU/memory/PCIe) and
  disk 7/11/51/153 (disk/controller I/O errors) -- these already log into
  the System log, so no extra `-LogName` is needed to see them.

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
| `-LogName`        | No       | Event log(s) to query. Defaults to `System`, `Application`, and `Microsoft-Windows-Hyper-V-VMMS-Admin` (silently skipped if that log doesn't exist on the target). |
| `-OutputPath`     | No       | CSV path for the full, untruncated event dump. Defaults to `.\crash-events-<ComputerName>-<timestamp>.csv` in the current directory. |

### Output

- Console table of all events found in the window, plus a highlighted
  "Possible crash/reboot indicators" table for known crash-related event
  IDs.
- A CSV file with the full, untruncated event set (all fields, all logs)
  for further review.

## Get-CrashRootCause.ps1

Automated root-cause drill-down for a host crash/reboot. Instead of you
supplying a time window up front, it looks up the host's actual
`LastBootUpTime`, auto-selects a window around it, pulls the same
System/Application/Hyper-V-VMMS-Admin events and crash/hardware indicator
flagging as `Get-CrashWindowEvents.ps1`, and additionally finds the
**largest gap in logging** in that window -- which usually brackets the
actual downtime, even when no clean `Kernel-Power 41`/`1074`/`6008` event
was logged (e.g. a hard reset from outside Windows).

### Prerequisites

Same as [Get-CrashWindowEvents.ps1](#get-crashwindoweventsps1) -- WinRM
reachable on the target host, and an account with rights to read event
logs and PowerShell-remote in.

### Usage

Let it auto-detect the window from the host's last boot time:

```powershell
.\Get-CrashRootCause.ps1 -ComputerName hvs044-01.mccoys.hq
```

Widen or narrow the auto-detected window around the boot time:

```powershell
.\Get-CrashRootCause.ps1 -ComputerName hvs044-01.mccoys.hq -LookbackHours 8 -LookaheadMinutes 60
```

Or pin your own explicit window, same as the other script:

```powershell
.\Get-CrashRootCause.ps1 -ComputerName hvs044-01.mccoys.hq -StartTime "2026-08-27 22:00:00" -EndTime "2026-08-28 07:00:00"
```

### Parameters

| Parameter            | Required | Description |
|------------------------|----------|-------------|
| `-ComputerName`       | No       | FQDN or hostname of the target machine. Prompted for if omitted. |
| `-Credential`         | No       | `PSCredential` for the target machine. Prompted for (username/password, console-based) if omitted. |
| `-StartTime`          | No       | Start of the time window. If omitted, auto-selected as `LastBootUpTime - LookbackHours`. |
| `-EndTime`            | No       | End of the time window. If omitted, auto-selected as `LastBootUpTime + LookaheadMinutes`. |
| `-LookbackHours`      | No       | Hours before last boot to include when auto-selecting the window. Default `4`. |
| `-LookaheadMinutes`   | No       | Minutes after last boot to include when auto-selecting the window. Default `30`. |
| `-LogName`            | No       | Event log(s) to query. Defaults to `System`, `Application`, and `Microsoft-Windows-Hyper-V-VMMS-Admin`. |
| `-OutputPath`         | No       | CSV path for the full, untruncated event dump. Defaults to `.\crash-root-cause-<ComputerName>-<timestamp>.csv` in the current directory. |

### Output

- A **Summary** section: host, last boot time, window queried, and the
  largest logging gap found (with the last event before and first event
  after it) -- your best first guess at the actual downtime window and
  what was happening right before/after it.
- A highlighted "Possible crash/reboot/hardware indicators" table.
- The full event table for the window.
- A CSV file with the full, untruncated event set for further review.

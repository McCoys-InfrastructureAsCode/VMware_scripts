# VMware_scripts

Scripts for pulling crash/reboot troubleshooting data from Windows hosts.

- [Get-CrashWindowEvents.ps1](#get-crashwindoweventsps1) -- pulls Windows
  event log entries for a host in a time window, for crash/reboot
  investigation.
- [Get-CrashRootCause.ps1](#get-crashrootcauseps1) -- automated root-cause
  drill-down: finds the host's actual last boot time, auto-selects a
  window around it, and detects the logging gap that likely brackets the
  actual downtime.
- [Get-CrashDumpAnalysis.ps1](#get-crashdumpanalysisps1) -- pulls the
  memory dump from a bugcheck and runs an automated `!analyze -v` against
  it, to identify the actual process/driver behind the crash.
- [get_idrac_memory_errors.py](#get_idrac_memory_errorspy) -- pulls DIMM
  health and memory-related log entries from a Dell iDRAC9 over Redfish,
  to check for hardware ECC errors independently of the OS.

Typical crash/reboot workflow: run `Get-CrashWindowEvents.ps1` first for a
broad look at what happened, then `Get-CrashRootCause.ps1` to narrow in on
the likely cause and downtime window -- both run over WinRM, so you don't
need iDRAC or vSphere console access for this kind of triage. If a
bugcheck (`WER-SystemErrorReporting` event `1001`) turns up and a dump was
saved, run `Get-CrashDumpAnalysis.ps1` next to pin down the actual culprit
process/driver rather than just the bugcheck code. If the culprit process
looks like it hit corrupted memory (garbled exception/context data) and
you want to rule hardware in or out, `get_idrac_memory_errors.py` checks
the host's out-of-band ECC error history, independent of anything the OS
saw.

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
| `-StartTime`      | No       | Start of the time window to query. Defaults to 12 hours before the current time if omitted. |
| `-EndTime`        | No       | End of the time window to query. Defaults to the current time if omitted. |
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

## Get-CrashDumpAnalysis.ps1

Pulls a memory dump (default `C:\Windows\MEMORY.DMP`) from the target host
over WinRM and runs an automated `cdb.exe -c "!analyze -v"` against it --
the same analysis WinDbg would give you, without needing console/RDP
access to the host. Useful once `Get-CrashWindowEvents.ps1` /
`Get-CrashRootCause.ps1` have shown a bugcheck (`WER-SystemErrorReporting`
event `1001`) and you want to know the actual process or driver behind it
(e.g. *which* process died behind a `0xEF CRITICAL_PROCESS_DIED`), not
just the bugcheck code.

Designed to be re-run: each run copies the dump to its own timestamped
file under `.\dumps\` (gitignored -- dumps can be huge), and caches
downloaded symbols under `.\symbols\` so repeat analyses don't
re-download them every time.

### Prerequisites

- Same WinRM reachability as the other scripts.
- **`cdb.exe`** installed locally -- easiest via
  `winget install --id Microsoft.WinDbg` (the modern WinDbg package
  bundles cdb.exe), or install "Debugging Tools for Windows" from the
  Windows SDK installer. The script auto-detects either, or point
  `-CdbPath` at an existing install.
- Outbound internet access to `https://msdl.microsoft.com` (Microsoft's
  public symbol server) for the first analysis of a given bugcheck --
  subsequent runs reuse the local symbol cache.

### Usage

```powershell
.\Get-CrashDumpAnalysis.ps1 -ComputerName hvs044-01.mccoys.hq
```

Point at a specific minidump instead of the default full/kernel dump:

```powershell
.\Get-CrashDumpAnalysis.ps1 -ComputerName hvs044-01.mccoys.hq -DumpPath 'C:\Windows\Minidump\082826-12345-01.dmp'
```

Keep the copied dump around afterward (e.g. to open it in WinDbg's GUI, or
to re-run analysis later without re-copying a large dump):

```powershell
.\Get-CrashDumpAnalysis.ps1 -ComputerName hvs044-01.mccoys.hq -KeepLocalDump
```

Re-analyze a dump you already have locally -- e.g. one kept via
`-KeepLocalDump` above -- with no remote connection made at all (handy for
re-running after a symbol/analysis tweak, without paying for the copy
again):

```powershell
.\Get-CrashDumpAnalysis.ps1 -LocalDumpPath .\dumps\hvs044-01.mccoys.hq-20260901-113803.DMP
```

### Parameters

| Parameter            | Required | Description |
|------------------------|----------|-------------|
| `-ComputerName`       | No       | FQDN or hostname of the target machine. Prompted for if omitted (unless `-LocalDumpPath` is used). |
| `-Credential`         | No       | `PSCredential` for the target machine. Prompted for (username/password, console-based) if omitted. |
| `-DumpPath`           | No       | Path to the dump file on the remote host. Defaults to `C:\Windows\MEMORY.DMP`. |
| `-LocalDumpDir`       | No       | Local folder the dump is copied into. Defaults to `.\dumps`. |
| `-LocalDumpPath`      | No       | Skip the remote pull and re-analyze a dump you already have locally. Ignores `-ComputerName`/`-Credential`/`-DumpPath`/`-LocalDumpDir` and never deletes the file. |
| `-CdbPath`            | No       | Path to `cdb.exe`. Auto-detected if omitted. |
| `-SymbolCachePath`    | No       | Local folder used to cache downloaded symbols across runs. Defaults to `.\symbols` (resolved to an absolute path before use). |
| `-SymbolServer`       | No       | Symbol server URL. Defaults to Microsoft's public symbol server. |
| `-OutputPath`         | No       | Path for the full `!analyze -v` text output. Defaults to `.\crash-dump-analysis-<name>-<timestamp>.txt`. |
| `-KeepLocalDump`      | No       | Switch. Keep the copied `.dmp` after analysis instead of deleting it. Ignored (never deletes) when `-LocalDumpPath` is used. |

### Output

- A highlighted "Bugcheck analysis highlights" section in the console --
  the bucketed fields `!analyze -v` reports (e.g. `PROCESS_NAME`,
  `FAILURE_BUCKET_ID`, `BUGCHECK_STR`).
- A text file with the full, untruncated `!analyze -v` output for further
  review.
- The copied `.dmp` is deleted after analysis unless `-KeepLocalDump` is
  passed (dumps can be large; both `.\dumps\` and `.\symbols\` are
  gitignored).

## get_idrac_memory_errors.py

Pulls DIMM inventory/health and memory-related entries from the System
Event Log and Lifecycle Log on a Dell iDRAC9, over Redfish -- an
out-of-band, firmware-level view of ECC memory errors, independent of
whatever (if anything) made it up to the OS/WHEA layer. Iterates over
however many DIMMs the Redfish `Memory` collection reports; nothing is
hardcoded to a specific DIMM count.

Per-DIMM ECC error counter fields vary by iDRAC firmware/generation, so
rather than hardcoding a specific field path, the script walks each
DIMM's `MemoryMetrics` resource and surfaces any field whose name
contains "ecc", "error", or "correctable" -- plus DIMM `Health`/`State`,
which is the more universally-supported signal.

### Prerequisites

- Python 3 with the `requests` package (`pip install requests`).
- Network access to the iDRAC's HTTPS interface (typically port 443) and
  an iDRAC account with read access to Systems/Managers/logs (the default
  `root` account works; use `--username` for anything else).

### Usage

```powershell
python get_idrac_memory_errors.py --idrac idrac-hvs044-01.mccoys.hq
```

Self-signed iDRAC certificate (common for internal iDRACs):

```powershell
python get_idrac_memory_errors.py --idrac idrac-hvs044-01.mccoys.hq --insecure
```

Widen or narrow how far back log entries are pulled (default 30 days):

```powershell
python get_idrac_memory_errors.py --idrac idrac-hvs044-01.mccoys.hq --since-days 90
```

### Parameters

| Argument         | Required | Description |
|-------------------|----------|-------------|
| `--idrac`         | Yes      | iDRAC hostname or IP. |
| `--username`      | No       | iDRAC account. Defaults to `root`. Password is always prompted for interactively -- never pass it on the command line. |
| `--insecure`      | No       | Skip TLS certificate verification (for iDRACs with self-signed certs). |
| `--since-days`    | No       | Only include log entries from the last N days. Defaults to `30`. |
| `--output-dir`    | No       | Directory to write the full JSON report into. Defaults to the current directory. |

### Output

- Console summary: each DIMM's `Health`/`State`/capacity, flagging any
  that aren't `Health=OK`, plus any ECC/error-related fields found in its
  `MemoryMetrics`.
- Console listing of System Event Log and Lifecycle Log entries (within
  `--since-days`) that mention memory/DIMM/ECC/correctable.
- A full JSON report (`idrac-memory-report-<idrac>-<timestamp>.json`) with
  the raw DIMM data, `MemoryMetrics`, and all matched log entries, for
  cases where the console summary doesn't surface what you need.

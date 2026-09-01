#!/usr/bin/env python3
"""
Pulls DIMM health/inventory and memory-related log entries from a Dell
iDRAC9 over Redfish, to check for ECC memory errors independently of
whatever the OS/WHEA layer saw. Log services (System Event Log, Lifecycle
Log, etc.) are discovered dynamically rather than assumed by name, since
their exact ids/paths vary across iDRAC firmware/generations.

Requires: pip install requests

Usage:
    python get_idrac_memory_errors.py --idrac idrac-hvs044-01.mccoys.hq

Username and password are always prompted for interactively if not
supplied via --username (default 'root' if left blank at the prompt) --
never pass the password on the command line.
"""

import argparse
import getpass
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    import requests
    import urllib3
except ImportError:
    sys.exit("This script requires the 'requests' package: pip install requests")

MEMORY_KEYWORDS = ("memory", "dimm", "ecc", "correctable")


def get_json(session, base_url, path, timeout=60):
    resp = session.get(f"{base_url}{path}", timeout=timeout)
    resp.raise_for_status()
    return resp.json()


def find_first_member_id(session, base_url, collection_path, label, timeout=60):
    data = get_json(session, base_url, collection_path, timeout=timeout)
    members = data.get("Members", [])
    if not members:
        raise RuntimeError(f"No {label} found on this iDRAC")
    return members[0]["@odata.id"].rstrip("/").rsplit("/", 1)[-1]


def extract_error_fields(obj, prefix=""):
    """Walk a JSON object and pull out any scalar field that looks
    ECC/error-related. Dell's exact schema for per-DIMM error counters
    varies by firmware/generation, so this is deliberately generic rather
    than hardcoding a field path that might not exist on your iDRAC."""
    found = {}
    if isinstance(obj, dict):
        for key, value in obj.items():
            key_path = f"{prefix}.{key}" if prefix else key
            lowered = key.lower()
            if any(term in lowered for term in ("ecc", "error", "correctable")):
                if not isinstance(value, (dict, list)):
                    found[key_path] = value
            if isinstance(value, (dict, list)):
                found.update(extract_error_fields(value, key_path))
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            found.update(extract_error_fields(item, f"{prefix}[{i}]"))
    return found


def get_collection_members(session, base_url, collection_path, timeout=60):
    """Fetch every Member of a Redfish collection, following
    Members@odata.nextLink pagination -- some iDRAC collections (e.g.
    Memory with many DIMMs) can span more than one page."""
    members = []
    path = collection_path
    while path:
        data = get_json(session, base_url, path, timeout=timeout)
        members.extend(data.get("Members", []))
        path = data.get("Members@odata.nextLink") or data.get("@odata.nextLink")
    return members


def get_memory_inventory(session, base_url, system_id, timeout=60):
    members = get_collection_members(session, base_url, f"/redfish/v1/Systems/{system_id}/Memory", timeout=timeout)
    dimms = []
    for member in members:
        dimm_path = member["@odata.id"]
        dimm = get_json(session, base_url, dimm_path, timeout=timeout)
        entry = {
            "Name": dimm.get("Name"),
            "CapacityMiB": dimm.get("CapacityMiB"),
            "Health": (dimm.get("Status") or {}).get("Health"),
            "State": (dimm.get("Status") or {}).get("State"),
            "OperatingSpeedMhz": dimm.get("OperatingSpeedMhz"),
        }
        metrics_path = f"{dimm_path.rstrip('/')}/MemoryMetrics"
        try:
            metrics = get_json(session, base_url, metrics_path, timeout=timeout)
            entry["MemoryMetrics"] = metrics
            entry["ErrorFields"] = extract_error_fields(metrics)
        except requests.HTTPError:
            entry["MemoryMetrics"] = None
            entry["ErrorFields"] = {}
        dimms.append(entry)
    return dimms


def discover_log_services(session, base_url, resource_path, timeout=60):
    """Return [{'id', 'name', 'entries_path'}, ...] for every log service
    under a resource (e.g. /redfish/v1/Systems/System.Embedded.1 or
    /redfish/v1/Managers/iDRAC.Embedded.1). Log service names/ids (e.g.
    "Sel" vs "SEL", "Lclog" vs "LC") vary across iDRAC firmware/
    generations, so this discovers them rather than assuming fixed names."""
    services = []
    try:
        data = get_json(session, base_url, f"{resource_path}/LogServices", timeout=timeout)
    except requests.HTTPError:
        return services
    for member in data.get("Members", []):
        svc_path = member["@odata.id"]
        try:
            svc = get_json(session, base_url, svc_path, timeout=timeout)
        except requests.HTTPError:
            continue
        entries_path = (svc.get("Entries") or {}).get("@odata.id")
        if entries_path:
            services.append(
                {
                    "id": svc.get("Id") or svc_path.rstrip("/").rsplit("/", 1)[-1],
                    "name": svc.get("Name"),
                    "entries_path": entries_path,
                }
            )
    return services


def paginate_log_entries(session, base_url, entries_path, since, timeout=60):
    entries = []
    path = entries_path
    while path:
        data = get_json(session, base_url, path, timeout=timeout)
        for e in data.get("Members", []):
            created = e.get("Created")
            if since and created:
                try:
                    ts = datetime.fromisoformat(created.replace("Z", "+00:00"))
                    if ts < since:
                        continue
                except ValueError:
                    pass
            entries.append(e)
        path = data.get("Members@odata.nextLink") or data.get("@odata.nextLink")
    return entries


def filter_memory_related(entries):
    matches = []
    for e in entries:
        text = json.dumps(e).lower()
        if any(k in text for k in MEMORY_KEYWORDS):
            matches.append(e)
    return matches


def main():
    parser = argparse.ArgumentParser(
        description="Pull DIMM health/ECC error info and memory-related log entries from a Dell iDRAC9 via Redfish."
    )
    parser.add_argument("--idrac", required=True, help="iDRAC hostname or IP")
    parser.add_argument("--username", default=None, help="iDRAC username. Prompted for if omitted (default: root)")
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Skip TLS certificate verification (common for iDRACs with self-signed certs)",
    )
    parser.add_argument(
        "--since-days",
        type=int,
        default=30,
        help="Only include log entries from the last N days (default: 30)",
    )
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory to write the full JSON report into (default: current directory)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Per-request timeout in seconds (default: 60). Increase this if login is backed by "
        "Active Directory/LDAP, which can be slower than local iDRAC accounts.",
    )
    args = parser.parse_args()

    if not args.username:
        args.username = input(f"Username for {args.idrac} (default: root): ") or "root"
    password = getpass.getpass(f"Password for {args.username}@{args.idrac}: ")
    base_url = f"https://{args.idrac}"

    session = requests.Session()
    session.auth = (args.username, password)
    session.verify = not args.insecure
    session.headers.update({"Accept": "application/json"})
    if args.insecure:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    try:
        print(f"Connecting to {args.idrac} (timeout {args.timeout}s per request) ...")
        system_id = find_first_member_id(session, base_url, "/redfish/v1/Systems", "Systems", timeout=args.timeout)
        manager_id = find_first_member_id(session, base_url, "/redfish/v1/Managers", "Managers", timeout=args.timeout)

        print("Pulling DIMM inventory and per-DIMM memory metrics ...")
        dimms = get_memory_inventory(session, base_url, system_id, timeout=args.timeout)

        system = get_json(session, base_url, f"/redfish/v1/Systems/{system_id}", timeout=args.timeout)
        reported_total_gib = (system.get("MemorySummary") or {}).get("TotalSystemMemoryGiB")

        since = datetime.now(timezone.utc) - timedelta(days=args.since_days)

        print("Discovering log services ...")
        log_services = discover_log_services(
            session, base_url, f"/redfish/v1/Systems/{system_id}", timeout=args.timeout
        )
        log_services += discover_log_services(
            session, base_url, f"/redfish/v1/Managers/{manager_id}", timeout=args.timeout
        )
        if not log_services:
            print("  No log services discovered.")
        else:
            print("  Found: " + ", ".join(svc["name"] or svc["id"] for svc in log_services))

        all_entries = []
        for svc in log_services:
            label = svc["name"] or svc["id"]
            print(f"Pulling {label} ...")
            try:
                entries = paginate_log_entries(session, base_url, svc["entries_path"], since, timeout=args.timeout)
            except requests.HTTPError as exc:
                print(f"  Skipping {label}: {exc}")
                continue
            for e in entries:
                e["_LogService"] = label
            all_entries.extend(entries)
    except requests.exceptions.Timeout:
        sys.exit(
            f"Request to {args.idrac} timed out after {args.timeout}s. If this account is authenticated "
            "via Active Directory/LDAP, try --timeout with a larger value, or use a local iDRAC account."
        )
    except requests.exceptions.RequestException as exc:
        sys.exit(f"Failed talking to iDRAC at {args.idrac}: {exc}")

    memory_entries = filter_memory_related(all_entries)

    print(f"\n=== DIMM health ({len(dimms)} DIMM(s) enumerated) ===")
    unhealthy = []
    for d in dimms:
        health = d["Health"]
        flag = ""
        if health not in (None, "OK"):
            flag = "  <-- NOT OK"
            unhealthy.append(d)
        print(f"  {d['Name']!s:<12} Health={health!s:<10} State={d['State']!s:<10} {d['CapacityMiB']} MiB{flag}")
        for k, v in d["ErrorFields"].items():
            print(f"      {k}: {v}")

    enumerated_gib = sum((d.get("CapacityMiB") or 0) for d in dimms) / 1024
    if reported_total_gib is not None:
        if abs(enumerated_gib - reported_total_gib) > 1:
            print(
                f"\nWARNING: enumerated DIMMs total {enumerated_gib:.0f} GiB, but the system "
                f"reports {reported_total_gib} GiB installed. Some DIMM(s) may be missing from "
                "this report, or actually missing/failed in the hardware -- check the web UI's "
                "System > Memory page directly to confirm which."
            )
        else:
            print(f"\nEnumerated DIMM capacity ({enumerated_gib:.0f} GiB) matches system-reported total memory.")

    if unhealthy:
        print(f"\n{len(unhealthy)} DIMM(s) reporting non-OK health -- see above.")
    else:
        print(
            "\nAll DIMMs report Health=OK. This doesn't rule out correctable ECC "
            "events (which don't always flip Health) -- check the error fields "
            "above and the log entries below."
        )

    print(f"\n=== Memory-related log entries (last {args.since_days}d): {len(memory_entries)} ===")
    for e in memory_entries:
        print(f"  [{e.get('_LogService')}] {e.get('Created')}  {e.get('Message')}")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_path = Path(args.output_dir) / f"idrac-memory-report-{args.idrac}-{stamp}.json"
    report = {
        "idrac": args.idrac,
        "generated": datetime.now(timezone.utc).isoformat(),
        "since_days": args.since_days,
        "log_services_found": [svc["name"] or svc["id"] for svc in log_services],
        "reported_total_system_memory_gib": reported_total_gib,
        "enumerated_dimm_capacity_gib": enumerated_gib,
        "dimms": dimms,
        "memory_entries": memory_entries,
    }
    output_path.write_text(json.dumps(report, indent=2))
    print(f"\nFull report (including raw MemoryMetrics and all matched log entries) written to {output_path}")


if __name__ == "__main__":
    main()

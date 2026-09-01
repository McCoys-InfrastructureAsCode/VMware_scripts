#!/usr/bin/env python3
"""
Pulls DIMM health/inventory and memory-related log entries (System Event
Log + Lifecycle Log) from a Dell iDRAC9 over Redfish, to check for ECC
memory errors independently of whatever the OS/WHEA layer saw.

Requires: pip install requests

Usage:
    python get_idrac_memory_errors.py --idrac idrac-hvs044-01.mccoys.hq

Never pass the password on the command line -- it's always prompted for
interactively (use --username to change the account, default 'root').
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


def get_json(session, base_url, path):
    resp = session.get(f"{base_url}{path}", timeout=30)
    resp.raise_for_status()
    return resp.json()


def find_first_member_id(session, base_url, collection_path, label):
    data = get_json(session, base_url, collection_path)
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


def get_memory_inventory(session, base_url, system_id):
    data = get_json(session, base_url, f"/redfish/v1/Systems/{system_id}/Memory")
    dimms = []
    for member in data.get("Members", []):
        dimm_path = member["@odata.id"]
        dimm = get_json(session, base_url, dimm_path)
        entry = {
            "Name": dimm.get("Name"),
            "CapacityMiB": dimm.get("CapacityMiB"),
            "Health": (dimm.get("Status") or {}).get("Health"),
            "State": (dimm.get("Status") or {}).get("State"),
            "OperatingSpeedMhz": dimm.get("OperatingSpeedMhz"),
        }
        metrics_path = f"{dimm_path.rstrip('/')}/MemoryMetrics"
        try:
            metrics = get_json(session, base_url, metrics_path)
            entry["MemoryMetrics"] = metrics
            entry["ErrorFields"] = extract_error_fields(metrics)
        except requests.HTTPError:
            entry["MemoryMetrics"] = None
            entry["ErrorFields"] = {}
        dimms.append(entry)
    return dimms


def paginate_log_entries(session, base_url, entries_path, since):
    entries = []
    path = entries_path
    while path:
        data = get_json(session, base_url, path)
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
    parser.add_argument("--username", default="root", help="iDRAC username (default: root)")
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
    args = parser.parse_args()

    password = getpass.getpass(f"Password for {args.username}@{args.idrac}: ")
    base_url = f"https://{args.idrac}"

    session = requests.Session()
    session.auth = (args.username, password)
    session.verify = not args.insecure
    session.headers.update({"Accept": "application/json"})
    if args.insecure:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    try:
        print(f"Connecting to {args.idrac} ...")
        system_id = find_first_member_id(session, base_url, "/redfish/v1/Systems", "Systems")
        manager_id = find_first_member_id(session, base_url, "/redfish/v1/Managers", "Managers")

        print("Pulling DIMM inventory and per-DIMM memory metrics ...")
        dimms = get_memory_inventory(session, base_url, system_id)

        since = datetime.now(timezone.utc) - timedelta(days=args.since_days)

        print("Pulling System Event Log ...")
        sel_entries = paginate_log_entries(
            session, base_url, f"/redfish/v1/Systems/{system_id}/LogServices/Sel/Entries", since
        )

        print("Pulling Lifecycle Log ...")
        try:
            lc_entries = paginate_log_entries(
                session, base_url, f"/redfish/v1/Managers/{manager_id}/LogServices/Lclog/Entries", since
            )
        except requests.HTTPError:
            lc_entries = []
    except requests.exceptions.RequestException as exc:
        sys.exit(f"Failed talking to iDRAC at {args.idrac}: {exc}")

    sel_memory_entries = filter_memory_related(sel_entries)
    lc_memory_entries = filter_memory_related(lc_entries)

    print("\n=== DIMM health ===")
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

    if unhealthy:
        print(f"\n{len(unhealthy)} DIMM(s) reporting non-OK health -- see above.")
    else:
        print(
            "\nAll DIMMs report Health=OK. This doesn't rule out correctable ECC "
            "events (which don't always flip Health) -- check the error fields "
            "above and the log entries below."
        )

    print(f"\n=== Memory-related System Event Log entries (last {args.since_days}d): {len(sel_memory_entries)} ===")
    for e in sel_memory_entries:
        print(f"  {e.get('Created')}  {e.get('Message')}")

    print(f"\n=== Memory-related Lifecycle Log entries (last {args.since_days}d): {len(lc_memory_entries)} ===")
    for e in lc_memory_entries:
        print(f"  {e.get('Created')}  {e.get('Message')}")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_path = Path(args.output_dir) / f"idrac-memory-report-{args.idrac}-{stamp}.json"
    report = {
        "idrac": args.idrac,
        "generated": datetime.now(timezone.utc).isoformat(),
        "since_days": args.since_days,
        "dimms": dimms,
        "sel_memory_entries": sel_memory_entries,
        "lc_memory_entries": lc_memory_entries,
    }
    output_path.write_text(json.dumps(report, indent=2))
    print(f"\nFull report (including raw MemoryMetrics and all matched log entries) written to {output_path}")


if __name__ == "__main__":
    main()

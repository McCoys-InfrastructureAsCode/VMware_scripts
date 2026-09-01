#!/usr/bin/env python3
"""
Triggers a Dell SupportAssist Collection on an iDRAC9 over Redfish and
waits for it to complete, so you don't have to babysit the web UI for the
several minutes a collection takes.

SupportAssist Collection bundles hardware inventory, the Lifecycle Log,
System Event Log, TTY log, and (optionally) OS-level data into a single
.zip -- useful alongside Get-CrashDumpAnalysis.ps1 and
get_idrac_memory_errors.py as a broader cross-check when investigating a
crash.

Without a network share configured, the finished bundle is stored on the
iDRAC's own internal storage. Dell doesn't expose a documented, stable
Redfish/racadm path to pull a locally-stored bundle directly -- only to
push it to a CIFS/NFS/HTTP(S) share -- so this script stops at
"collection complete" and tells you where to download it manually
(Maintenance > SupportAssist > SupportAssist Collections in the web UI).
If you set up a share later, add ShareType/IPAddress/ShareName/Username/
Password fields to COLLECT_BODY below to push the export there directly.

Exact Redfish action names/payload fields for SupportAssist have shifted
a bit across iDRAC9 firmware revisions. If a call 404s, this script
fetches DellLCService's actual advertised Actions and prints them, so you
can see what this firmware really calls things rather than guessing
blind.

Requires: pip install requests

Usage:
    python start_support_assist_collection.py --idrac 10.200.44.133 --insecure

Username and password are always prompted for interactively if not
supplied via --username (default 'root' if left blank at the prompt) --
never pass the password on the command line.
"""

import argparse
import getpass
import sys
import time

try:
    import requests
    import urllib3
except ImportError:
    sys.exit("This script requires the 'requests' package: pip install requests")

TERMINAL_STATES = ("Completed", "CompletedWithErrors", "Failed", "Exception")
SUCCESS_STATES = ("Completed", "CompletedWithErrors")

# iDRAC's embedded Redfish service is a fairly resource-constrained daemon
# and has been observed returning a spurious 404/5xx for a resource that
# a moment earlier (or a moment later) responds fine, under sustained
# request load. Retry these with backoff rather than treating the first
# one as authoritative; a *persistently* missing resource still ends up
# failing the same way after retries are exhausted.
RETRYABLE_STATUS_CODES = {404, 429, 500, 502, 503, 504}


def idrac_request(session, base_url, method, path, body=None, timeout=60, max_retries=3, backoff_base=2):
    url = path if path.startswith("http") else f"{base_url}{path}"
    attempt = 0
    while True:
        attempt += 1
        try:
            resp = session.request(method, url, json=body, timeout=timeout)
            resp.raise_for_status()
            return resp
        except requests.HTTPError as exc:
            status = exc.response.status_code if exc.response is not None else None
            if status in RETRYABLE_STATUS_CODES and attempt <= max_retries:
                wait = backoff_base * (2 ** (attempt - 1))
                print(f"  {method} {path} returned {status}, retrying in {wait}s (attempt {attempt}/{max_retries}) ...")
                time.sleep(wait)
                continue
            raise
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as exc:
            if attempt <= max_retries:
                wait = backoff_base * (2 ** (attempt - 1))
                print(
                    f"  {method} {path} failed ({exc.__class__.__name__}), retrying in {wait}s "
                    f"(attempt {attempt}/{max_retries}) ..."
                )
                time.sleep(wait)
                continue
            raise


def find_dell_lc_service_path(session, base_url, timeout, max_retries, backoff_base):
    """Follow the Manager resource's own advertised Links.Oem.Dell.DellLCService
    link rather than guessing a URL -- confirmed (via a manual Redfish dump
    against a 16G PowerEdge) to live under Managers/<id>/Oem/Dell/DellLCService,
    not under Systems/<id> as older docs/examples for this API often show."""
    managers = idrac_request(
        session, base_url, "GET", "/redfish/v1/Managers", timeout=timeout, max_retries=max_retries, backoff_base=backoff_base
    ).json()
    manager_id = managers["Members"][0]["@odata.id"].rstrip("/").rsplit("/", 1)[-1]
    manager = idrac_request(
        session,
        base_url,
        "GET",
        f"/redfish/v1/Managers/{manager_id}",
        timeout=timeout,
        max_retries=max_retries,
        backoff_base=backoff_base,
    ).json()
    dell_links = ((manager.get("Links") or {}).get("Oem") or {}).get("Dell") or {}
    lc_service = dell_links.get("DellLCService")
    if not lc_service or "@odata.id" not in lc_service:
        raise RuntimeError(
            f"DellLCService link not found under Managers/{manager_id}/Links/Oem/Dell on this firmware -- "
            "SupportAssist Collection may not be exposed the way this script expects. Available Dell OEM "
            f"links there: {', '.join(dell_links.keys()) or '(none)'}"
        )
    return lc_service["@odata.id"]


def print_available_actions(session, base_url, service_path, timeout, max_retries, backoff_base):
    try:
        svc = idrac_request(
            session, base_url, "GET", service_path, timeout=timeout, max_retries=max_retries, backoff_base=backoff_base
        ).json()
        actions = svc.get("Actions", {})
        if actions:
            print(f"Actions advertised by {service_path} on this firmware:")
            for name in actions:
                print(f"  {name}")
    except requests.RequestException as exc:
        print(f"Could not re-fetch {service_path} to list its actions: {exc}")


def poll_job(session, base_url, job_path, poll_interval, max_wait_minutes, timeout, max_retries, backoff_base):
    deadline = time.time() + max_wait_minutes * 60
    state = None
    while time.time() < deadline:
        time.sleep(poll_interval)
        job = idrac_request(
            session, base_url, "GET", job_path, timeout=timeout, max_retries=max_retries, backoff_base=backoff_base
        ).json()
        state = job.get("JobState") or job.get("TaskState")
        pct = job.get("PercentComplete")
        print(f"  Job state: {state} ({pct}%)")
        if state in TERMINAL_STATES:
            break
    return state


def main():
    parser = argparse.ArgumentParser(
        description="Trigger a Dell SupportAssist Collection on an iDRAC9 via Redfish and wait for it to complete."
    )
    parser.add_argument("--idrac", required=True, help="iDRAC hostname or IP")
    parser.add_argument("--username", default=None, help="iDRAC username. Prompted for if omitted (default: root)")
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Skip TLS certificate verification (common for iDRACs with self-signed certs)",
    )
    parser.add_argument(
        "--data-selector",
        nargs="+",
        default=["HWData", "TTYLogData", "TelemetryReports"],
        help="Data types to collect (default: HWData TTYLogData TelemetryReports -- pure hardware/firmware "
        "data, no OS credentials needed). Add OSAppData for OS-level data, but note that may require "
        "additional OS credential fields this script doesn't currently set.",
    )
    parser.add_argument("--poll-interval", type=int, default=15, help="Seconds between job status checks (default: 15)")
    parser.add_argument(
        "--max-wait-minutes",
        type=int,
        default=30,
        help="Give up waiting after this many minutes; the collection keeps running on the iDRAC regardless (default: 30)",
    )
    parser.add_argument("--timeout", type=int, default=60, help="Per-request timeout in seconds (default: 60)")
    parser.add_argument(
        "--max-retries",
        type=int,
        default=3,
        help="Retry a request this many times on a 404/429/5xx or connection error before giving up -- iDRAC's "
        "embedded Redfish service has been observed returning spurious errors for a resource that works a "
        "moment earlier/later under sustained request load (default: 3)",
    )
    parser.add_argument(
        "--retry-backoff",
        type=int,
        default=2,
        help="Base seconds for retry backoff, doubling each attempt (2s, 4s, 8s, ...) (default: 2)",
    )
    args = parser.parse_args()

    if not args.username:
        args.username = input(f"Username for {args.idrac} (default: root): ") or "root"
    password = getpass.getpass(f"Password for {args.username}@{args.idrac}: ")
    base_url = f"https://{args.idrac}"

    session = requests.Session()
    session.auth = (args.username, password)
    session.verify = not args.insecure
    if args.insecure:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    job_location = None
    try:
        print(f"Connecting to {args.idrac} ...")
        lc_service_path = find_dell_lc_service_path(session, base_url, args.timeout, args.max_retries, args.retry_backoff)
        print(f"Using DellLCService at {lc_service_path}")

        try:
            print("Checking SupportAssist EULA status ...")
            eula = idrac_request(
                session,
                base_url,
                "POST",
                f"{lc_service_path}/Actions/DellLCService.SupportAssistGetEULAStatus",
                body={},
                timeout=args.timeout,
                max_retries=args.max_retries,
                backoff_base=args.retry_backoff,
            ).json()
            if eula.get("EULAStatus") != "Accepted":
                print("Accepting SupportAssist EULA ...")
                idrac_request(
                    session,
                    base_url,
                    "POST",
                    f"{lc_service_path}/Actions/DellLCService.SupportAssistAcceptEULA",
                    body={},
                    timeout=args.timeout,
                    max_retries=args.max_retries,
                    backoff_base=args.retry_backoff,
                )
        except requests.HTTPError as exc:
            print(f"EULA check/accept failed: {exc}")
            print_available_actions(session, base_url, lc_service_path, args.timeout, args.max_retries, args.retry_backoff)
            raise

        print(f"Starting SupportAssist Collection (data: {', '.join(args.data_selector)}) ...")
        collect_body = {"ShareType": "Local", "DataSelectorArrayIn": args.data_selector}
        try:
            collect_resp = idrac_request(
                session,
                base_url,
                "POST",
                f"{lc_service_path}/Actions/DellLCService.SupportAssistCollection",
                body=collect_body,
                timeout=args.timeout,
                max_retries=args.max_retries,
                backoff_base=args.retry_backoff,
            )
        except requests.HTTPError as exc:
            print(f"SupportAssistCollection call failed: {exc}")
            print_available_actions(session, base_url, lc_service_path, args.timeout, args.max_retries, args.retry_backoff)
            raise

        job_location = collect_resp.headers.get("Location")
        if not job_location:
            sys.exit(
                f"iDRAC didn't return a job location for the collection request (HTTP {collect_resp.status_code}). "
                f"Check {lc_service_path} / the web UI's Job Queue manually."
            )
        print(f"Collection job started: {job_location}")

        state = poll_job(
            session,
            base_url,
            job_location,
            args.poll_interval,
            args.max_wait_minutes,
            args.timeout,
            args.max_retries,
            args.retry_backoff,
        )
    except requests.exceptions.Timeout:
        sys.exit(f"Request to {args.idrac} timed out after {args.timeout}s.")
    except requests.exceptions.RequestException as exc:
        sys.exit(f"Failed talking to iDRAC at {args.idrac}: {exc}")

    if state not in SUCCESS_STATES:
        sys.exit(
            f"Collection job did not reach a completed state (last seen: {state}). It may still be running on "
            f"the iDRAC -- check {job_location} or the web UI's Job Queue."
        )

    print(f"\nCollection finished (state: {state}).")
    print("No network share was configured, so the bundle is stored on the iDRAC's own internal storage.")
    print(f"Download it manually: https://{args.idrac}/ -> Maintenance -> SupportAssist -> SupportAssist Collections")


if __name__ == "__main__":
    main()

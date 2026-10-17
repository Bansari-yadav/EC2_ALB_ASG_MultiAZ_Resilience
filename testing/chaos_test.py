
#!/usr/bin/env python3
"""Terminate an ASG instance and measure ALB recovery."""

import argparse
import csv
import sys
import time
from pathlib import Path

from aws_helpers import (
    get_inservice_instance_id,
    terminate_instance_via_asg,
)
from http_probe import probe_once

def load_env(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    return values

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tier", choices=["uploader", "viewer"], required=True)
    parser.add_argument("--slo-seconds", type=float, default=None)
    parser.add_argument("--poll-interval", type=float, default=2)
    parser.add_argument("--max-wait", type=float, default=600)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    env = {
        **load_env(root / ".env"),
        **load_env(root / "stack_outputs.env"),
    }

    region = env.get("AWS_REGION", "us-east-2")
    dns = env["ALB_DNS_NAME"]
    slo = args.slo_seconds
    if slo is None:
        slo = float(env.get("RECOVERY_SLO_SECONDS", 180))

    if args.tier == "uploader":
        port = env["UPLOADER_LISTENER_PORT"]
        asg = env["UPLOADER_ASG_NAME"]
    else:
        port = env["VIEWER_LISTENER_PORT"]
        asg = env["VIEWER_ASG_NAME"]

    url = f"http://{dns}:{port}/"
    print(f"Target: {args.tier} at {url}", flush=True)
    print(f"Recovery SLO: {slo:.0f} seconds", flush=True)

    if not probe_once(url):
        sys.exit("ERROR: Endpoint is not healthy before the test.")

    instance_id = get_inservice_instance_id(asg, region)
    if not instance_id:
        sys.exit("ERROR: No InService instance found.")

    print(f"Terminating instance {instance_id} via ASG...", flush=True)

    start = time.monotonic()
    terminate_instance_via_asg(instance_id, region)

    log = []
    went_down = False
    recovered_at = None

    while time.monotonic() - start <= args.max_wait:
        elapsed = round(time.monotonic() - start, 2)
        is_up = probe_once(url)
        log.append((elapsed, is_up))

        if not is_up and not went_down:
            went_down = True
            print(f"Endpoint DOWN at {elapsed}s", flush=True)

        if went_down and is_up:
            recovered_at = elapsed
            print(f"Endpoint UP at {elapsed}s", flush=True)
            break

        time.sleep(args.poll_interval)

    output = root / f"chaos_test_{args.tier}_{int(time.time())}.csv"

    with open(output, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["elapsed_seconds", "is_up"])
        writer.writerows(log)

    print(f"Poll log written to {output}", flush=True)

    if recovered_at is None:
        print("FAIL: Endpoint did not recover within the test window.")
        sys.exit(1)

    print(f"Recovery time: {recovered_at:.1f}s (SLO: {slo:.0f}s)")

    if recovered_at <= slo:
        print("PASS: recovery time met the SLO.")
    else:
        print("FAIL: recovery time exceeded the SLO.")
        sys.exit(1)

if __name__ == "__main__":
    main()

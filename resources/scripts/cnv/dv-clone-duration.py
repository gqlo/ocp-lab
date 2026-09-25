#!/usr/bin/env python3
"""Report DataVolume clone duration in a namespace (creation → clone complete)."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone


def parse_ts(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def format_duration(seconds: float) -> str:
    if seconds < 0:
        return f"{seconds:.3f}s"
    whole = int(seconds)
    ms = seconds - whole
    if whole >= 3600:
        h, rem = divmod(whole, 3600)
        m, s = divmod(rem, 60)
        return f"{h}h {m}m {s}s" + (f" {ms * 1000:.0f}ms" if ms else "")
    if whole >= 60:
        m, s = divmod(whole, 60)
        return f"{m}m {s}s" + (f" {ms * 1000:.0f}ms" if ms else "")
    if whole:
        return f"{whole}s" + (f" {ms * 1000:.0f}ms" if ms else "")
    return f"{seconds:.3f}s"


def clone_end_time(dv: dict) -> datetime | None:
    status = dv.get("status") or {}
    for cond in status.get("conditions") or []:
        if cond.get("type") != "Running":
            continue
        if cond.get("status") != "False":
            continue
        if cond.get("reason") in ("Completed", "Succeeded") or "Clone Complete" in (
            cond.get("message") or ""
        ):
            ts = cond.get("lastTransitionTime")
            if ts:
                return parse_ts(ts)

    if status.get("phase") == "Succeeded":
        times = [
            parse_ts(c["lastTransitionTime"])
            for c in status.get("conditions") or []
            if c.get("lastTransitionTime")
        ]
        if times:
            return max(times)
    return None


def dv_clone_seconds(dv: dict) -> float | None:
    created = dv.get("metadata", {}).get("creationTimestamp")
    if not created:
        return None
    end = clone_end_time(dv)
    if end is None:
        return None
    return (end - parse_ts(created)).total_seconds()


def fetch_dvs(namespace: str) -> list[dict]:
    proc = subprocess.run(
        ["oc", "get", "datavolume", "-n", namespace, "-o", "json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or f"oc failed (exit {proc.returncode})")
    payload = json.loads(proc.stdout)
    return payload.get("items") or []


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Calculate DataVolume clone time in a namespace.",
    )
    parser.add_argument("namespace", help="Namespace containing DataVolumes")
    parser.add_argument(
        "--name",
        help="Only report this DataVolume name (default: all in namespace)",
    )
    args = parser.parse_args()

    try:
        dvs = fetch_dvs(args.namespace)
    except json.JSONDecodeError as exc:
        print(f"invalid JSON from oc: {exc}", file=sys.stderr)
        return 1

    if args.name:
        dvs = [d for d in dvs if d.get("metadata", {}).get("name") == args.name]
        if not dvs:
            print(f"no DataVolume {args.name!r} in {args.namespace}", file=sys.stderr)
            return 1

    if not dvs:
        print(f"no DataVolumes in {args.namespace}")
        return 0

    rows: list[tuple[str, float, str]] = []
    for dv in sorted(dvs, key=lambda d: d["metadata"]["name"]):
        name = dv["metadata"]["name"]
        phase = (dv.get("status") or {}).get("phase", "?")
        seconds = dv_clone_seconds(dv)
        if seconds is None:
            print(f"{name}\tphase={phase}\tclone_time=unknown")
            continue
        rows.append((name, seconds, phase))
        print(f"{name}\tphase={phase}\tclone_time={format_duration(seconds)}\t({seconds:.3f}s)")

    if len(rows) > 1:
        times = [s for _, s, _ in rows]
        total = sum(times)
        print("---")
        print(f"count={len(rows)}  total={format_duration(total)} ({total:.3f}s)")
        print(f"min={format_duration(min(times))}  max={format_duration(max(times))}")
        print(f"avg={format_duration(total / len(times))}")

    unknown = len(dvs) - len(rows)
    return 1 if unknown and not rows else 0


if __name__ == "__main__":
    sys.exit(main())

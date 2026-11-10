#!/usr/bin/python3
"""Measure only the short-lived native helper using synthetic, isolated events."""
import argparse
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=Path)
parser.add_argument("--events", type=int, default=100)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
count = min(10000, max(10, args.events))
payload = json.dumps({"session_id": "synthetic-benchmark", "prompt": "x" * 4096}).encode()

with tempfile.TemporaryDirectory(prefix="lidglow-benchmark-") as temporary:
    base = Path(temporary).resolve()
    environment = dict(os.environ, LIDGLOW_HOME=str(base / "home"), LIDGLOW_DATA_DIR=str(base / "data"))

    def invoke(state):
        started = time.perf_counter()
        result = subprocess.run([str(binary), "event", "--source", "custom", "--state", state],
                                input=payload, capture_output=True, env=environment, timeout=2)
        if result.returncode or result.stdout or result.stderr:
            raise RuntimeError("Signal invocation failed or emitted unexpected output")
        return (time.perf_counter() - started) * 1000

    for _ in range(10):
        invoke("working")
    reports = {}
    for label, changed in [("coalesced_working", False), ("state_changes", True)]:
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        timings = [invoke("complete" if changed and index % 2 else "working") for index in range(count)]
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        ordered = sorted(timings)
        reports[label] = {
            "events": count,
            "median_ms": round(statistics.median(timings), 3),
            "p95_ms": round(ordered[min(count - 1, int(count * 0.95))], 3),
            "max_ms": round(max(timings), 3),
            "child_cpu_ms_per_event": round(((after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)) * 1000 / count, 3),
            "peak_child_rss_mib": round(after.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024), 3),
        }
    files = list((base / "data/events").glob("*.json"))
    if len(files) != 1:
        raise RuntimeError("Expected exactly one isolated session snapshot")
    print(json.dumps({"helper": reports, "scope": "Synthetic helper process only; not app RAM, energy, or battery endurance."}, indent=2))

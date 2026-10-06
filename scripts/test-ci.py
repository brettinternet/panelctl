#!/usr/bin/env python3
"""Run CI tests with stack evidence if the test process hangs."""
import os
import signal
import subprocess
import sys

process = subprocess.Popen(
    ["swift", "test", "--disable-sandbox"], start_new_session=True
)
try:
    sys.exit(process.wait(timeout=240))
except subprocess.TimeoutExpired:
    print("Tests exceeded four minutes; sampling XCTest processes.", flush=True)
    matches = subprocess.run(
        ["pgrep", "-f", r"\.xctest"], capture_output=True, text=True, check=False
    )
    for pid in matches.stdout.split():
        try:
            subprocess.run(
                ["sample", pid, "1", "-file", f"test-stack-{pid}.log"],
                timeout=10, check=False,
            )
        except subprocess.TimeoutExpired:
            print(f"Sampling process {pid} timed out.", flush=True)
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    sys.exit(124)

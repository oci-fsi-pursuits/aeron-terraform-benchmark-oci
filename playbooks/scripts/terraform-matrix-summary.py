#!/usr/bin/env python3
"""Emit terraform-matrix-summary.json next to driver-matrix-*-summary.csv (controller)."""
from __future__ import annotations

import csv
import io
import json
import sys
from pathlib import Path

AGG_HEADER_PREFIX = "archive,scenario,valid_runs"


def _split_summary_sections(text: str) -> tuple[str, str]:
    """Return (mode_status_csv_block, latency_csv_block). Latency block starts at aggregate header line."""
    lines = text.splitlines()
    start_lat = None
    for i, line in enumerate(lines):
        if line.strip().startswith(AGG_HEADER_PREFIX):
            start_lat = i
            break
    if start_lat is None:
        return text, ""
    head = "\n".join(lines[:start_lat]).strip()
    tail = "\n".join(lines[start_lat:]).strip()
    return head, tail


def _load_mode_status(csv_block: str) -> list[dict]:
    if not csv_block.strip():
        return []
    rows: list[dict] = []
    f = io.StringIO(csv_block)
    r = csv.DictReader(f)
    if not r.fieldnames or "mode" not in r.fieldnames:
        return []
    for row in r:
        rows.append(
            {
                "mode": (row.get("mode") or "").strip(),
                "status": (row.get("status") or "").strip(),
                "notes": (row.get("notes") or "").strip(),
            }
        )
    return rows


def _load_latency_rows(csv_block: str) -> list[dict]:
    if not csv_block.strip():
        return []
    rows: list[dict] = []
    f = io.StringIO(csv_block)
    for row in csv.DictReader(f):
        try:
            rows.append(
                {
                    "archive": row.get("archive", ""),
                    "scenario": row.get("scenario", ""),
                    "valid_runs": int(row.get("valid_runs") or 0),
                    "median_p50_us": float(row["median_p50_us"]),
                    "median_p99_us": float(row["median_p99_us"]),
                    "median_p999_us": float(row["median_p999_us"]),
                    "median_max_us": float(row["median_max_us"]),
                }
            )
        except (KeyError, ValueError) as e:
            sys.stderr.write(f"terraform-matrix-summary: skip row ({e}): {row}\n")
    return rows


def _load_summary_file(csv_path: Path) -> tuple[list[dict], list[dict]]:
    if not csv_path.is_file():
        return [], []
    text = csv_path.read_text(encoding="utf-8")
    mode_block, lat_block = _split_summary_sections(text)
    return _load_mode_status(mode_block), _load_latency_rows(lat_block)


def main() -> int:
    if len(sys.argv) < 6:
        print("usage: terraform-matrix-summary.py RESULTS_DIR profile runs iters warm", file=sys.stderr)
        return 1
    results_dir = Path(sys.argv[1])
    profile = sys.argv[2]
    try:
        runs = int(sys.argv[3])
        iters = int(sys.argv[4])
        warm = int(sys.argv[5])
    except ValueError:
        runs, iters, warm = 1, 1, 1

    echo_status, echo_lat = _load_summary_file(results_dir / "driver-matrix-echo-summary.csv")
    cluster_status, cluster_lat = _load_summary_file(results_dir / "driver-matrix-cluster-summary.csv")

    out = {
        "matrix_profile": profile,
        "benchmark_echo_runs": runs,
        "benchmark_echo_iterations": iters,
        "benchmark_echo_warmup_iterations": warm,
        "echo_mode_status": echo_status,
        "echo_modes": echo_lat,
        "cluster_mode_status": cluster_status,
        "cluster_modes": cluster_lat,
    }
    dest = results_dir / "terraform-matrix-summary.json"
    dest.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"Wrote {dest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

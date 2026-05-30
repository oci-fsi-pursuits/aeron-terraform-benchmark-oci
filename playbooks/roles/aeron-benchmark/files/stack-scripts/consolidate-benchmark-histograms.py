#!/usr/bin/env python3
"""Merge driver-matrix-*-summary.csv latency tables into histogram-style CSVs (all rows + best per scenario)."""
from __future__ import annotations

import argparse
import csv
import io
import sys
from pathlib import Path

AGG_HEADER_PREFIX = "archive,scenario,valid_runs"


def _latency_block(text: str) -> str:
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip().startswith(AGG_HEADER_PREFIX):
            start = i
            break
    if start is None:
        return ""
    return "\n".join(lines[start:])


def _parse_rows(block: str) -> list[dict]:
    rows: list[dict] = []
    if not block.strip():
        return rows
    for row in csv.DictReader(io.StringIO(block)):
        try:
            vr = int((row.get("valid_runs") or "0").strip() or 0)
        except ValueError:
            vr = 0
        try:
            p50 = float(row["median_p50_us"])
            p99 = float(row["median_p99_us"])
            p999 = float(row["median_p999_us"])
            pmax = float(row["median_max_us"])
        except (KeyError, ValueError):
            continue
        p9999_s = (row.get("median_p9999_us") or "").strip()
        p9999 = float(p9999_s) if p9999_s else None
        rows.append(
            {
                "archive": (row.get("archive") or "").strip(),
                "scenario": (row.get("scenario") or "").strip(),
                "valid_runs": vr,
                "p50": p50,
                "p99": p99,
                "p999": p999,
                "p9999": p9999,
                "max": pmax,
            }
        )
    return rows


def _emit_row(r: dict) -> dict[str, str]:
    return {
        "patterns": r["scenario"],
        "p50": f"{r['p50']:.6f}",
        "p99": f"{r['p99']:.6f}",
        "p999": f"{r['p999']:.6f}",
        "p9999": f"{r['p9999']:.6f}" if r["p9999"] is not None else "",
        "max": f"{r['max']:.6f}",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output-dir", type=Path, required=True)
    ap.add_argument("--output-prefix", required=True)
    ap.add_argument("summary_files", nargs="+", type=Path)
    args = ap.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    all_rows: list[dict] = []
    for path in args.summary_files:
        if not path.is_file():
            print(f"consolidate-benchmark-histograms: skip missing {path}", file=sys.stderr)
            continue
        all_rows.extend(_parse_rows(_latency_block(path.read_text(encoding="utf-8"))))

    fieldnames = ["patterns", "p50", "p99", "p999", "p9999", "max"]
    all_path = args.output_dir / f"{args.output_prefix}-all.csv"
    with all_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in all_rows:
            if r["valid_runs"] <= 0:
                continue
            w.writerow(_emit_row(r))

    by_scenario: dict[str, list[dict]] = {}
    for r in all_rows:
        if r["valid_runs"] <= 0:
            continue
        by_scenario.setdefault(r["scenario"], []).append(r)

    best_path = args.output_dir / f"{args.output_prefix}-best-of-all.csv"
    with best_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for scenario in sorted(by_scenario.keys()):
            cand = by_scenario[scenario]
            best = min(cand, key=lambda x: (x["p99"], x["p999"], x["max"]))
            w.writerow(_emit_row(best))

    print(all_path)
    print(best_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

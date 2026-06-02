#!/usr/bin/env python3
"""Aggregate local LLM token usage.

Reads the JSONL written by mcp_localllm.py (default: ./usage.log) and prints a
daily / per-tool summary of call counts and token consumption.

Usage:
    python3 usage_report.py                 # summarize ./usage.log
    python3 usage_report.py path/to/usage.log
    python3 usage_report.py --by tool       # group by tool only
    python3 usage_report.py --by day        # group by day only
    python3 usage_report.py --json          # machine-readable totals
"""

import argparse
import json
import os
import sys
from collections import defaultdict


def _load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def _key(row, by):
    day = (row.get("ts") or "")[:10]
    tool = row.get("tool") or "?"
    if by == "day":
        return (day,)
    if by == "tool":
        return (tool,)
    return (day, tool)


def _agg(rows, by):
    buckets = defaultdict(lambda: {"calls": 0, "prompt": 0, "completion": 0, "total": 0})
    for r in rows:
        b = buckets[_key(r, by)]
        b["calls"] += 1
        b["prompt"] += r.get("prompt_tokens") or 0
        b["completion"] += r.get("completion_tokens") or 0
        b["total"] += r.get("total_tokens") or 0
    return buckets


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("logfile", nargs="?", default=os.path.join(here, "usage.log"))
    ap.add_argument("--by", choices=["day", "tool", "day-tool"], default="day-tool")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = ap.parse_args()

    if not os.path.exists(args.logfile):
        print(f"no usage log found: {args.logfile}", file=sys.stderr)
        return 1

    rows = _load(args.logfile)
    if not rows:
        print("usage log is empty", file=sys.stderr)
        return 1

    buckets = _agg(rows, args.by)

    if args.json:
        out = [{"key": list(k), **v} for k, v in sorted(buckets.items())]
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    hdr_key = {"day": ["day"], "tool": ["tool"], "day-tool": ["day", "tool"]}[args.by]
    keyw = max([len(" / ".join(map(str, k))) for k in buckets] + [len(" / ".join(hdr_key))])
    print(f"{' / '.join(hdr_key):<{keyw}}  {'calls':>6}  {'prompt':>9}  {'compl':>9}  {'total':>9}")
    print("-" * (keyw + 40))
    tot = {"calls": 0, "prompt": 0, "completion": 0, "total": 0}
    for k, v in sorted(buckets.items()):
        label = " / ".join(map(str, k))
        print(f"{label:<{keyw}}  {v['calls']:>6}  {v['prompt']:>9}  {v['completion']:>9}  {v['total']:>9}")
        for f in tot:
            tot[f] += v[f]
    print("-" * (keyw + 40))
    print(f"{'TOTAL':<{keyw}}  {tot['calls']:>6}  {tot['prompt']:>9}  {tot['completion']:>9}  {tot['total']:>9}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

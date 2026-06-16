#!/usr/bin/env python3
"""Aggregate local LLM + Codex + Claude usage.

Reads the JSONL logs written by mcp_localllm.py (usage_localllm.log),
mcp_codex.py (usage_codex.log), and mcp_claude.py (usage_claude.log) and prints
a summary of call counts, token consumption, and latency. All logs share the
same schema; Codex and Claude rows have null token fields (neither reports token
counts), so token columns reflect local-LLM usage only while call/latency
columns cover all sources.

Usage:
    python3 usage_report.py                      # both default logs
    python3 usage_report.py usage_codex.log      # one explicit file
    python3 usage_report.py a.log b.log          # several files
    python3 usage_report.py --by source          # group by source only
    python3 usage_report.py --by tool            # group by tool only
    python3 usage_report.py --by day             # group by day only
    python3 usage_report.py --by source-tool     # source + tool
    python3 usage_report.py --json               # machine-readable totals
"""

import argparse
import json
import os
import sys
from collections import defaultdict

DEFAULT_LOGS = ["usage_localllm.log", "usage_codex.log", "usage_claude.log"]


def _source_from_path(path):
    base = os.path.basename(path)
    if base.startswith("usage_") and base.endswith(".log"):
        return base[len("usage_"):-len(".log")]
    return base


def _load(path):
    rows = []
    fallback_source = _source_from_path(path)
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            row.setdefault("source", fallback_source)
            rows.append(row)
    return rows


def _key(row, by):
    day = (row.get("ts") or "")[:10]
    tool = row.get("tool") or "?"
    source = row.get("source") or "?"
    parts = {
        "day": (day,),
        "tool": (tool,),
        "source": (source,),
        "day-tool": (day, tool),
        "source-tool": (source, tool),
        "day-source": (day, source),
    }
    return parts[by]


def _agg(rows, by):
    buckets = defaultdict(
        lambda: {"calls": 0, "prompt": 0, "completion": 0, "total": 0, "latency": 0.0}
    )
    for r in rows:
        b = buckets[_key(r, by)]
        b["calls"] += 1
        b["prompt"] += r.get("prompt_tokens") or 0
        b["completion"] += r.get("completion_tokens") or 0
        b["total"] += r.get("total_tokens") or 0
        b["latency"] += r.get("latency_s") or 0.0
    return buckets


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument(
        "logfiles",
        nargs="*",
        default=[os.path.join(here, n) for n in DEFAULT_LOGS],
    )
    ap.add_argument(
        "--by",
        choices=["day", "tool", "source", "day-tool", "source-tool", "day-source"],
        default="source-tool",
    )
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = ap.parse_args()

    rows = []
    found = []
    for path in args.logfiles:
        if os.path.exists(path):
            rows.extend(_load(path))
            found.append(path)
    if not found:
        print("no usage logs found: " + ", ".join(args.logfiles), file=sys.stderr)
        return 1
    if not rows:
        print("usage logs are empty", file=sys.stderr)
        return 1

    buckets = _agg(rows, args.by)

    if args.json:
        out = [{"key": list(k), **v} for k, v in sorted(buckets.items())]
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    hdr_key = args.by.split("-")
    keyw = max(
        [len(" / ".join(map(str, k))) for k in buckets] + [len(" / ".join(hdr_key))]
    )
    print(
        f"{' / '.join(hdr_key):<{keyw}}  {'calls':>6}  {'prompt':>9}  "
        f"{'compl':>9}  {'total':>9}  {'lat_s':>8}"
    )
    print("-" * (keyw + 51))
    tot = {"calls": 0, "prompt": 0, "completion": 0, "total": 0, "latency": 0.0}
    for k, v in sorted(buckets.items()):
        label = " / ".join(map(str, k))
        print(
            f"{label:<{keyw}}  {v['calls']:>6}  {v['prompt']:>9}  "
            f"{v['completion']:>9}  {v['total']:>9}  {v['latency']:>8.1f}"
        )
        for f in tot:
            tot[f] += v[f]
    print("-" * (keyw + 51))
    print(
        f"{'TOTAL':<{keyw}}  {tot['calls']:>6}  {tot['prompt']:>9}  "
        f"{tot['completion']:>9}  {tot['total']:>9}  {tot['latency']:>8.1f}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

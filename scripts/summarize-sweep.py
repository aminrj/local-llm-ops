#!/usr/bin/env python3
"""Collapse results/bench-*.json into one comparison table.

Prints a row per config per context depth, plus a decode/prompt-eval summary
so you can see which config actually wins at the depths you work at rather
than at the depth that flatters the number.
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
RESULTS = REPO / "results"


def load():
    runs = {}
    for p in sorted(RESULTS.glob("bench-*.json")):
        try:
            d = json.loads(p.read_text())
        except json.JSONDecodeError:
            continue
        # Keep the newest run per label.
        runs[d["label"]] = d
    return runs


def main() -> int:
    runs = load()
    if not runs:
        print("No results in results/. Run: bash scripts/sweep.sh", file=sys.stderr)
        return 1

    depths = sorted({r["target_tokens"] for d in runs.values() for r in d["rows"]})

    print("Prompt eval (tok/s) — higher is better\n")
    _table(runs, depths, "prompt_per_sec")
    print("\nDecode (tok/s) — higher is better\n")
    _table(runs, depths, "gen_per_sec")

    print("\nConfig details\n")
    w = max(len(k) for k in runs)
    print(f"{'config':<{w}}  {'n_ctx':>7}  {'accept':>7}")
    print("-" * (w + 18))
    for label, d in runs.items():
        acc = next(
            (r["draft_accept"] for r in d["rows"] if r.get("draft_accept") is not None),
            None,
        )
        print(f"{label:<{w}}  {d.get('n_ctx', '-'):>7}  {acc if acc else '-':>7}")

    return 0


def _table(runs, depths, key):
    w = max(len(k) for k in runs)
    hdr = f"{'config':<{w}}" + "".join(f"{d:>10}" for d in depths)
    print(hdr)
    print("-" * len(hdr))
    # Best value per depth, for marking.
    best = {}
    for d in depths:
        vals = [
            r[key]
            for run in runs.values()
            for r in run["rows"]
            if r["target_tokens"] == d and r.get(key) is not None
        ]
        best[d] = max(vals) if vals else None
    for label, run in runs.items():
        by_depth = {r["target_tokens"]: r.get(key) for r in run["rows"]}
        cells = ""
        for d in depths:
            v = by_depth.get(d)
            if v is None:
                cells += f"{'-':>10}"
            elif best[d] and v == best[d]:
                cells += f"{('*' + str(v)):>10}"
            else:
                cells += f"{v:>10}"
        print(f"{label:<{w}}{cells}")


if __name__ == "__main__":
    sys.exit(main())

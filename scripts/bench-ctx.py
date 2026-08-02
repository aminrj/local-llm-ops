#!/usr/bin/env python3
"""Throughput at realistic context depths.

scripts/benchmark.sh measures short prompts, which is not where this box
spends its time: the codemode logs show a median request around 37k tokens
and a long tail past 100k. Prompt-eval and decode both fall off with depth,
so a 500-token benchmark will happily tell you a config is fine when it is
not.

Reads llama.cpp's own `timings` block when the server provides it, and falls
back to wall clock otherwise.

  python3 scripts/bench-ctx.py --port 8081 --label baseline
  python3 scripts/bench-ctx.py --port 8083 --label mtp
"""

import argparse
import json
import pathlib
import random
import statistics
import sys
import time
import urllib.error
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent

# Deterministic filler. Code-shaped so the tokenizer behaves roughly the way
# it does on a real repo, seeded so every run and every config sees the same
# prompts.
WORDS = """fn let mut impl struct enum match return async await pub crate self
Result Option Vec String HashMap Arc Mutex RwLock trait where for while loop
if else break continue const static type use mod super dyn ref move box send
sync clone debug default from into try unwrap expect map filter fold collect""".split()


def make_prompt(approx_tokens: int, seed: int = 1234) -> str:
    rng = random.Random(seed)
    # ~1.4 tokens per whitespace-separated word for this kind of filler.
    n_words = int(approx_tokens / 1.4)
    lines, cur = [], []
    for i in range(n_words):
        cur.append(rng.choice(WORDS))
        if len(cur) >= 12:
            lines.append("    " + " ".join(cur) + ";")
            cur = []
    if cur:
        lines.append("    " + " ".join(cur) + ";")
    body = "\n".join(lines)
    return (
        "Below is a fragment of generated source. Reply with exactly the "
        "single word ACK, nothing else.\n\n```rust\n" + body + "\n```\n"
    )


def post(url: str, payload: dict, timeout: int):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def run_one(base: str, model: str, target: int, gen: int, timeout: int) -> dict:
    prompt = make_prompt(target)
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": gen,
        "stream": False,
        "temperature": 0.6,
        "top_p": 0.95,
        "top_k": 20,
        "cache_prompt": False,
    }
    t0 = time.perf_counter()
    resp = post(f"{base}/v1/chat/completions", payload, timeout)
    wall = time.perf_counter() - t0

    usage = resp.get("usage", {}) or {}
    timings = resp.get("timings", {}) or {}
    n_prompt = usage.get("prompt_tokens", 0)
    n_gen = usage.get("completion_tokens", 0)

    pp = timings.get("prompt_per_second")
    tg = timings.get("predicted_per_second")
    source = "server"
    if pp is None or tg is None:
        # No timings block — wall clock can only give a blended number.
        source = "wallclock"
        pp = None
        tg = round(n_gen / wall, 2) if wall > 0 and n_gen else None

    # Speculative acceptance, when the server is drafting. This is the only
    # trustworthy per-request signal that speculation is actually engaged --
    # /props reports request-level defaults, not the server's --spec-type.
    draft_n = timings.get("draft_n")
    draft_acc = timings.get("draft_n_accepted")
    accept = round(draft_acc / draft_n, 3) if draft_n else None

    return {
        "target_tokens": target,
        "prompt_tokens": n_prompt,
        "gen_tokens": n_gen,
        "prompt_per_sec": round(pp, 1) if pp else None,
        "gen_per_sec": round(tg, 1) if tg else None,
        "wall_sec": round(wall, 2),
        "timing_source": source,
        "draft_accept": accept,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--label", required=True, help="name for this config, e.g. baseline / mtp")
    ap.add_argument("--model", default="", help="model alias; blank = whatever is loaded")
    ap.add_argument(
        "--ctx-sizes",
        default="1000,16000,48000,96000",
        help="approximate prompt sizes to test",
    )
    ap.add_argument("--gen-tokens", type=int, default=256)
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()

    base = f"http://{args.host}:{args.port}"

    try:
        with urllib.request.urlopen(f"{base}/props", timeout=10) as r:
            props = json.load(r)
    except (urllib.error.URLError, OSError) as e:
        print(f"ERROR: no server on {base} ({e})", file=sys.stderr)
        return 1

    model = args.model or props.get("model_alias", "")
    n_ctx = props.get("default_generation_settings", {}).get("n_ctx")
    # Deliberately not reporting default_generation_settings.params
    # ["speculative.types"] here: that is the per-request default and reads
    # "none" even when the server was started with --spec-type draft-mtp,
    # which is actively misleading in a speculation A/B. The draft acceptance
    # column below is the real signal, and the server log is authoritative:
    #   grep 'adding speculative implementation' <logfile>
    print(f"server   : {base}")
    print(f"model    : {model}")
    print(f"n_ctx    : {n_ctx}")
    print()

    targets = [int(x) for x in args.ctx_sizes.split(",") if x.strip()]
    for t in targets:
        if n_ctx and t + args.gen_tokens > n_ctx:
            print(f"skipping {t}: exceeds n_ctx {n_ctx}")
    targets = [t for t in targets if not n_ctx or t + args.gen_tokens <= n_ctx]

    rows = []
    hdr = (
        f"{'ctx':>8}  {'prompt tok':>10}  {'pp tok/s':>9}  {'tg tok/s':>9}  "
        f"{'wall s':>7}  {'accept':>6}"
    )
    print(hdr)
    print("-" * len(hdr))

    for t in targets:
        runs = []
        for i in range(args.repeats):
            try:
                r = run_one(base, model, t, args.gen_tokens, args.timeout)
            except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
                print(f"{t:>8}  FAILED: {e}")
                break
            runs.append(r)
            time.sleep(2)
        if not runs:
            continue
        med = {
            "target_tokens": t,
            "prompt_tokens": runs[0]["prompt_tokens"],
            "gen_tokens": statistics.median(x["gen_tokens"] for x in runs),
            "prompt_per_sec": _med(runs, "prompt_per_sec"),
            "gen_per_sec": _med(runs, "gen_per_sec"),
            "wall_sec": round(statistics.median(x["wall_sec"] for x in runs), 2),
            "timing_source": runs[0]["timing_source"],
            "draft_accept": _med(runs, "draft_accept", digits=3),
            "runs": runs,
        }
        rows.append(med)
        print(
            f"{t:>8}  {med['prompt_tokens']:>10}  "
            f"{_fmt(med['prompt_per_sec']):>9}  {_fmt(med['gen_per_sec']):>9}  "
            f"{med['wall_sec']:>7}  {_fmt(med['draft_accept']):>6}"
        )

    out_dir = REPO / "results"
    out_dir.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out = out_dir / f"bench-{args.label}-{stamp}.json"
    out.write_text(
        json.dumps(
            {
                "label": args.label,
                "timestamp": stamp,
                "server": base,
                "model": model,
                "n_ctx": n_ctx,
                "gen_tokens": args.gen_tokens,
                "repeats": args.repeats,
                "rows": rows,
            },
            indent=2,
        )
    )
    print(f"\nwrote {out.relative_to(REPO)}")
    return 0


def _med(runs, key, digits=1):
    vals = [x[key] for x in runs if x.get(key) is not None]
    return round(statistics.median(vals), digits) if vals else None


def _fmt(v):
    return "-" if v is None else f"{v}"


if __name__ == "__main__":
    sys.exit(main())

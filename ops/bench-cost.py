#!/usr/bin/env python3
"""Sum a pi agent run's token usage + cost from its persisted session jsonl.

pi records per-request usage on every assistant `message` event
(usage.input/output/cacheRead/cacheWrite + a pre-computed usage.cost.total),
persisted under $HOME/.pi/agent/sessions/ — which the bench bind-mounts to
$STATE_DIR/home, so it survives container removal. This reads those events and
prints a per-run total + token breakdown. Works retroactively on finished runs.

    python3 ops/bench-cost.py [SESSIONS_PATH]

SESSIONS_PATH is a session .jsonl, or any dir searched recursively for *.jsonl
(default: state/home/.pi/agent/sessions). Multiple sessions are summed, and a
per-session line is printed for each.
"""
import glob
import json
import os
import sys


def summarize(path: str) -> dict:
    tok = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "cacheWrite1h": 0, "reasoning": 0}
    cost = 0.0
    n = 0
    model = None
    t_first = t_last = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = ev.get("message") or {}
            u = msg.get("usage")
            if not u:
                continue
            n += 1
            model = msg.get("model") or model
            for k in tok:
                tok[k] += u.get(k, 0) or 0
            c = u.get("cost") or {}
            cost += c.get("total", 0.0) or 0.0
            ts = ev.get("timestamp") or msg.get("timestamp")
            if isinstance(ts, str):
                t_first = t_first or ts
                t_last = ts
    return {"session": os.path.basename(path), "model": model, "requests": n,
            "tokens": tok, "cost_usd": round(cost, 4),
            "first": t_first, "last": t_last}


def main() -> None:
    p = sys.argv[1] if len(sys.argv) > 1 else "state/home/.pi/agent/sessions"
    files = [p] if p.endswith(".jsonl") else sorted(glob.glob(os.path.join(p, "**", "*.jsonl"), recursive=True))
    if not files:
        print(f"no session jsonl under {p}", file=sys.stderr)
        sys.exit(1)

    sessions = [summarize(f) for f in files]
    total_cost = round(sum(s["cost_usd"] for s in sessions), 4)
    total_tok = {k: sum(s["tokens"][k] for s in sessions) for k in sessions[0]["tokens"]}
    total_req = sum(s["requests"] for s in sessions)

    for s in sessions:
        t = s["tokens"]
        print(f"  {s['session']}  model={s['model']}  reqs={s['requests']}  "
              f"in={t['input']} out={t['output']} cacheR={t['cacheRead']} cacheW={t['cacheWrite']}"
              f"(1h={t['cacheWrite1h']})  ${s['cost_usd']}", file=sys.stderr)

    out = {"cost_usd": total_cost, "requests": total_req, "tokens": total_tok,
           "sessions": len(sessions), "model": sessions[-1]["model"]}
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()

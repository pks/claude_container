#!/usr/bin/env python3
"""Generate K English canary source lines, seeded and reproducible. Mixed into
the decode input and excluded from scoring:

- the agent can't tell which lines count -> can't selectively memorize/hand-craft
  the real test subset;
- tripwire: a genuine NMT model, an LLM-passthrough, and a hardcoded lookup table
  each handle these lines differently, which is visible on the canary outputs.

    python3 make_canaries.py <K> <seed> <out.txt> [pool_file]

If pool_file is given (real dev-source sentences), canaries are SAMPLED from it,
so they are stylistically identical to the test source and can't be told apart
(audit LOW: canary detectability). Dev sentences are safe as canaries — they are
excluded from scoring, so recognizing one gains the agent nothing. Without a pool
file, a word-salad fallback is used. Regenerate per run (vary the seed).
"""
import random
import sys

# Common English word pool. Canaries are grammatical-ish but semantically random,
# so they look like English yet have no "correct" translation.
WORDS = (
    "time year people way day man thing woman life child world school state family "
    "student group country problem hand part place case week company system program "
    "question work government number night point home water room mother area money "
    "story fact month lot right study book eye job word business issue side kind head "
    "house service friend father power hour game line end member law car city community "
    "name president team minute idea body information back parent face others level office "
    "door health person art war history party result change morning reason research girl "
    "guy moment air teacher force education foot boy age policy process music market sense "
    "nation plan college interest death experience effect use class control care field "
    "development role effort rate heart drive company season report window bank "
    "run make take see come know get give find think tell become show leave feel put bring "
    "begin keep hold write stand hear let mean set meet pay sit speak lie lead read grow "
    "quick brown careful silent golden distant heavy narrow bright hollow gentle strange"
).split()


def sentence(rng: random.Random) -> str:
    n = rng.randint(6, 18)
    ws = [rng.choice(WORDS) for _ in range(n)]
    ws[0] = ws[0].capitalize()
    return " ".join(ws) + rng.choice([".", ".", ".", "?", "!"])


def main() -> None:
    k = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    out = sys.argv[3] if len(sys.argv) > 3 else "canaries.txt"
    pool_file = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
    rng = random.Random(seed)

    if pool_file:
        pool = [l.rstrip("\n") for l in open(pool_file) if l.strip()]
        if len(pool) < k:
            sys.exit(f"pool {pool_file} has {len(pool)} lines < K={k}")
        lines = rng.sample(pool, k)  # real dev-source sentences -> test-like decoys
        src = f"sampled from {pool_file}"
    else:
        lines = [sentence(rng) for _ in range(k)]  # word-salad fallback
        src = "word-salad"
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {k} canaries ({src}, seed {seed}) -> {out}")


if __name__ == "__main__":
    main()

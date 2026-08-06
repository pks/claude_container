#!/usr/bin/env python3
"""Generate K synthetic English canary source lines (novel, no valid German),
seeded and reproducible. Mixed into the decode input and excluded from scoring:

- the agent can't tell which lines count -> can't selectively memorize/hand-craft
  the real test subset;
- tripwire: a genuine NMT model, an LLM-passthrough, and a hardcoded lookup table
  each handle novel/gibberish input differently, which is visible on the canaries.

Regenerate per run (vary the seed) so canaries can't be learned across runs.

    python3 make_canaries.py <K> <seed> <out.txt>
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
    rng = random.Random(seed)
    with open(out, "w") as f:
        for _ in range(k):
            f.write(sentence(rng) + "\n")
    print(f"wrote {k} canaries (seed {seed}) -> {out}")


if __name__ == "__main__":
    main()

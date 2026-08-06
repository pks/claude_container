#!/usr/bin/env python3
"""Mix test source + canaries into one shuffled decode input, and record the
permutation so decode outputs can be un-shuffled and canaries stripped.

    python3 build_input.py <test.src> <canaries.txt> <decode_input.txt> <perm.json> <seed>

perm.json:  {"n_test", "n_canary", "order": [["t", i] | ["c", j], ...]}
where order[line] is the origin of that line in decode_input.txt.
"""
import json
import random
import sys


def main() -> None:
    test_src, canaries, out_input, out_perm = sys.argv[1:5]
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 0

    test = [l.rstrip("\n") for l in open(test_src)]
    can = [l.rstrip("\n") for l in open(canaries)]
    items = [("t", i, s) for i, s in enumerate(test)] + [("c", j, s) for j, s in enumerate(can)]
    random.Random(seed).shuffle(items)

    with open(out_input, "w") as f:
        for _, _, s in items:
            f.write(s + "\n")
    json.dump(
        {"n_test": len(test), "n_canary": len(can), "order": [[k, i] for (k, i, _) in items]},
        open(out_perm, "w"),
    )
    print(f"decode input: {len(items)} lines ({len(test)} test + {len(can)} canary) -> {out_input}")


if __name__ == "__main__":
    main()

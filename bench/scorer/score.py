#!/usr/bin/env python3
"""Un-permute decode output, strip canaries, sacreBLEU the test hyps vs refs.

    python3 score.py <out.hyp> <perm.json> <test.ref> <result.json>

sacreBLEU signature pinned: nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp.
"""
import json
import sys

import sacrebleu


def main() -> None:
    hyp_file, perm_file, ref_file, out_file = sys.argv[1:5]
    perm = json.load(open(perm_file))
    outputs = [l.rstrip("\n") for l in open(hyp_file)]
    refs = [l.rstrip("\n") for l in open(ref_file)]
    order = perm["order"]

    if len(outputs) != len(order):
        sys.exit(f"line-count mismatch: {len(outputs)} decode outputs vs {len(order)} inputs — void")
    if len(refs) != perm["n_test"]:
        sys.exit(f"ref count {len(refs)} != n_test {perm['n_test']} — void")

    test_hyps = [None] * perm["n_test"]
    canary_hyps = []
    for line, (kind, idx) in zip(outputs, order):
        if kind == "t":
            test_hyps[idx] = line
        else:
            canary_hyps.append(line)
    if any(h is None for h in test_hyps):
        sys.exit("missing test outputs after un-permute — void")

    metric = sacrebleu.BLEU(tokenize="13a", smooth_method="exp", lowercase=False)
    bleu = metric.corpus_score(test_hyps, [refs])
    result = {
        "test_bleu": round(bleu.score, 2),
        "sacrebleu_sig": metric.get_signature().format(),
        "n_test": len(test_hyps),
        "n_canary": len(canary_hyps),
        # canary sanity: a real translator emits non-empty, non-identical output for
        # gibberish; all-empty or verbatim-copy is a tripwire hit to inspect.
        "canary_nonempty": sum(1 for h in canary_hyps if h.strip()),
    }
    json.dump(result, open(out_file, "w"), indent=2)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

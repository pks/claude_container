# Bench scorer

Runs a submitted artifact on the **withheld** newstest2014 test and scores it
once. Lives outside the agent's world — holds the test data the agent never sees.

## Host requirements

A python (outside the airgap) with `sacrebleu` and `datasets`, plus docker with
the GPU runtime and the bench image built (`IMAGE`, has torch etc.).

## One-time setup

```
python3 prepare_test.py testdata/     # ONLINE: fetch newstest2014 -> testdata/{test.src,test.ref}
```
Keep `testdata/` only here. It must never be copied into the agent image.

## Score one submission

```
IMAGE=mtbench-container SEED=<run_seed> K=100 DECODE_BUDGET=3600 \
  ./score.sh /path/to/artifact
```
`artifact/` = the agent's deliverable: `model/` (≤10 GB) + executable `decode.sh`.

Flow:
1. pre-checks — `decode.sh` executable, `model/` present, `du(model) ≤ 10 GB` (else void).
2. `make_canaries.py` → K synthetic EN lines (seeded).
3. `build_input.py` → shuffle test.src + canaries into `decode_input.txt` + record `perm.json`.
4. `docker run --network none --gpus all -w /art IMAGE timeout $DECODE_BUDGET ./decode.sh /work/decode_input.txt /work/out.hyp`
   — **no network at all** (decode must be self-contained), time-bounded; non-zero exit or wrong line count = void.
5. `score.py` — un-permute, strip canaries, sacreBLEU (`nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`).

Output `result.json`: `test_bleu`, `sacrebleu_sig`, `n_test`, `n_canary`,
`canary_nonempty`, `decode_seconds`, `artifact_bytes`. That is the single read.

## Why this is the anti-cheat core

- The agent never sees the test source → cannot self-translate, hand-craft, or peek.
- Decode runs with `--network none` → a `decode.sh` that phones home or calls an
  LLM API fails.
- Canaries (excluded from score) hide which lines count and expose special-casing.
- 10 GB cap + no-network + from-scratch check bound smuggled pretrained models /
  lookup tables.

## TODO (runtime-verify, needs a docker+GPU host)

- Confirm `wmt/wmt14` `de-en` `test` resolves under the host `datasets` version.
- End-to-end dry run with a toy artifact (a `decode.sh` that copies input→output)
  to validate the permutation/strip/score plumbing before real submissions.

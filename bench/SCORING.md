# MachineTranslationModelingBench — Harness & Scoring Spec (v0)

Operator-facing. Defines what the harness provides, how it isolates the run, and how
it scores the submitted artifact. The agent never sees this — it sees `TASKCARD.md`.
en→de, WMT14.

## Isolation

- **Compute:** one on-demand (NOT spot) A100-80GB per run, uncapped. On-demand is
  deliberate — spot preemption confounds the modeling score with interruption-
  handling (learned the hard way in the pilot). Fixed, clean 12 h.
- **Network: egress deny-all except the agent's own inference endpoint.** One
  host/IP allow-listed (the model API the coding agent calls to reason); everything
  else blocked at the container/firewall level. This enforces, by construction:
  from-scratch (no weight downloads), no external data, no reference lookup, no
  `pip install` mid-run.
- **Offline tooling:** the image bakes every library/tool an MT run plausibly needs
  (torch, sentencepiece, subword-nmt, sacrebleu, tokenizers, fast_align, numpy/scipy,
  …) plus `HF_DATASETS_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, no `HF_TOKEN`. Bake
  generously — the agent cannot install anything.

## Data placement (the load-bearing split)

Baked **into the agent image**:
- WMT14 EN–DE **train** bitext (raw).
- **dev = newstest2013** with references.
- Nothing else. **No test data of any kind in the agent container.**

Held **only by the external scorer** (a separate process/container the agent cannot
reach):
- **test = newstest2014** source **and** references.
- The canary set (below).

Rationale: `wmt/wmt14` ships the test references; if the full dataset were cached in
the agent image, refs would be one file-read away regardless of network. Keeping all
test data out of the agent container is what actually protects the read.

## Submission → scoring flow

1. At 12 h (or on early "submit"), the harness freezes the workspace and takes the
   deliverable: `model/` + `decode.sh` + `RESULTS.md` + `STATUS.md`.
2. **Pre-checks (any failure → void or flagged):**
   - `du -sb model/` ≤ **10 GB**.
   - from-scratch: no pretrained weights (see Integrity checks).
   - `decode.sh` present and executable.
3. **Build the decode input:** take the withheld test **source** (N lines), inject
   **K synthetic canary lines** at known positions, shuffle-with-recorded-permutation
   → `decode_input.txt` (N+K lines). The agent's `decode.sh` sees only this.
4. **Run the artifact, offline, in a fresh copy of the same image**, no network at
   all (not even the inference endpoint — decode must be self-contained):
   `timeout <DECODE_BUDGET> ./decode.sh decode_input.txt out.hyp`
   Record decode wall-time. Non-zero exit / timeout / wrong line count → void.
5. **Un-permute, strip the K canaries**, leaving N hypotheses aligned to the test
   references.
6. **Score once:** sacreBLEU on the N pairs,
   signature `nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`. This is the number.
7. (Optional secondary) COMET on the same N — later.

There is no second submission. The read is the harness's, not the agent's.

## Canaries

- K synthetic source lines (e.g. 50–200) mixed into the decode input, excluded from
  scoring. Purpose: (a) the agent cannot tell which lines count, defeating selective
  memorization / hand-crafting of the real subset; (b) a tripwire — a genuine NMT
  model, an LLM-passthrough, and a hardcoded lookup table each handle novel/gibberish
  input differently, which is detectable on the canary outputs.
- Construction: plausible-but-novel EN sentences the agent's model has never seen and
  which have no "correct" DE (scrambled/recombined vocab, nonce entities). Regenerate
  per run so they can't be learned across runs.

## Integrity checks

- **From-scratch:** inspect the submitted init/config for pretrained provenance; the
  egress block already prevents downloading weights, and the 10 GB cap + canary
  behavior catch a smuggled model or lookup table. Optionally require the agent to
  log its random-init step and make the artifact reproducible from the logged seed.
- **Artifact-only decode:** step 4 runs with **no network at all** and only `model/`
  + baked deps — a `decode.sh` that tries to phone home or call an LLM API fails.
- **Self-report ignored:** any test number the agent writes in `RESULTS.md` is not
  used; a gap vs the harness score is a flag.
- **Determinism:** decode should be deterministic; the harness may run it twice and
  compare.

## Time enforcement

- Clock starts at the agent's first command; hard stop at 12 h (train + tuning +
  producing the artifact). At the cap the harness snapshots the workspace and takes
  whatever deliverable exists.
- `DECODE_BUDGET` (in the HOST file) bounds step 4 separately and is reported as the
  inference-cost axis of the Pareto — it is not part of the 12 h.

## Reported result

Per run: **(test BLEU, train wall-clock, decode time)** + the dev-BLEU-vs-wall-clock
curve. Reference line: Transformer-base ≈ 27. Ranking across frontier models is the
Pareto front over (BLEU, wall-clock), not a single scalar.

## Open / later

- COMET as a second metric.
- A fresher/less-standard test set to blunt residual pretraining-memory contamination
  of newstest2014 (defense-in-depth beyond the harness-runs-model design).
- Multi-seed bench replication (same model, N runs) to measure variance.

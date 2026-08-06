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

1. At the budget (or on early "submit"), the harness takes the agent's
   **`submission/`** dir (self-contained: `decode.sh` + `model/` + any code).
2. **Pre-checks (any failure → void or flagged):**
   - `du -sb submission/` ≤ **10 GB** — the cap is on the WHOLE submission dir, and
     only `submission/` is mounted (below), so weights can't hide outside it.
   - `decode.sh` present + executable; `model/` present.
   - from-scratch: advisory provenance scan (see Integrity checks).
3. **Build the decode input:** take the withheld test **source** (N lines), inject
   **K canary lines** at known positions, shuffle-with-recorded-permutation
   → `decode_input.txt` (N+K lines). The agent's `decode.sh` sees only this.
4. **Run the submission, locked down**, in a fresh copy of the same image, mounting
   ONLY `submission/` (ro) + a tmpfs scratch, with **no network at all**, dropped
   privileges (`--user` non-root, `--cap-drop ALL`, `--security-opt no-new-privileges`,
   `--pids-limit`), GPU on, time-bounded:
   `timeout <DECODE_BUDGET> ./decode.sh decode_input.txt out.hyp`
   Record decode wall-time. Non-zero exit / timeout / wrong line count → void.
5. **Un-permute, strip the K canaries**, leaving N hypotheses aligned to the test
   references.
6. **Score once:** sacreBLEU on the N pairs,
   signature `nrefs:1|case:mixed|eff:no|tok:13a|smooth:exp`. This is the number.
7. (Optional secondary) COMET on the same N — later.

There is no second submission. The read is the harness's, not the agent's.

## Canaries

- K source lines (e.g. 50–200) mixed into the decode input, excluded from scoring.
  Purpose: (a) the agent cannot tell which lines count, defeating selective
  memorization / hand-crafting of the real subset; (b) a tripwire — a genuine NMT
  model, an LLM-passthrough, and a hardcoded lookup table each handle them
  differently, which is detectable on the canary outputs.
- Construction: **sampled from real dev source** (newstest2013 English) so canaries
  are stylistically identical to the test source and can't be told apart (audit LOW).
  Dev lines are safe as canaries — they're excluded from scoring, so recognizing one
  gains the agent nothing. Fallback (no dev pool): word-salad EN. Regenerate
  per run so they can't be learned across runs.

## Integrity checks

- **From-scratch:** inspect the submitted init/config for pretrained provenance; the
  egress block already prevents downloading weights, and the 10 GB cap + canary
  behavior catch a smuggled model or lookup table. Optionally require the agent to
  log its random-init step and make the artifact reproducible from the logged seed.
- **Submission-only decode:** step 4 runs with **no network at all**, mounting only
  `submission/` (ro) + baked deps + a tmpfs — a `decode.sh` that phones home / calls
  an LLM API fails, and nothing outside `submission/` (ckpt/, .venv, logs) is reachable.
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

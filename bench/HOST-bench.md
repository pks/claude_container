# HOST — MachineTranslationModelingBench

Host-specific facts for a bench run. Staged to `doc/HOST.md` (via `make bench-stage`)
so the agent sees it alongside the task card. Keep it plan-agnostic — only
environment facts, no recipe.

## Machine

- 1 × A100-80GB, uncapped. Single GPU (`GPU=all`).
- **Preemptible**: the host may be reclaimed at any time. Your run is checkpointed
  and resumed from the workspace; the compute clock pauses during downtime. Keep
  `model/` + `decode.sh` + `STATUS.md` current so a resume continues cleanly.

## Storage

- Workspace and home persist at `$STATE_DIR` on a durable volume that survives
  preemption. Everything under `/workspace` is what you keep; write your model,
  `decode.sh`, and status there.

## Data

- Corpus baked at `$MTBENCH_DATA` (`/opt/mtbench/wmt14`): `datasets.load_from_disk`
  → `train` + `validation` (dev). No test split (withheld). Offline — nothing else
  to fetch.

## Network

- Offline except the reasoning endpoint. No `pip install`, no downloads, no dataset
  fetches — everything you need is baked in.

## Budget

- **12 h of active compute** (`BENCH_BUDGET_S=43200`), preemption-paused. Not wall time.

## Decode budget (harness-side, not your clock)

- The harness runs your `decode.sh` on the withheld test with a time limit of
  **`DECODE_BUDGET`** (default 3600 s) on the same 1×A100, `--network none`. Make
  decode fit — a system that can't decode the test in time doesn't score.

## Operator notes (not for the agent)

- Build: `make image` (builds `mtbench-container`, bakes WMT14 train+dev, downloads
  online at build then goes offline).
- Stage + run: `make bench-stage && make seed && make bench` (or `bench-egress.sh`).
- Preemptible auto-resume: `sudo bash ops/host-resume/install.sh` after setting
  `/etc/mtbench-resume.env` (see `mtbench-resume.env.example`).
- Score a submission: `bench/scorer/prepare_test.py` once, then
  `bench/scorer/score.sh <state>/workspace`.

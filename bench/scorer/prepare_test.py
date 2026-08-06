#!/usr/bin/env python3
"""One-time, host-side, ONLINE. Fetch WMT14 de-en and write, into the scorer's
private testdata dir:
  test.src / test.ref  — newstest2014 source + reference (the withheld test)
  dev.src              — newstest2013 source only (real sentences used as
                         stylistically-matched canaries; see make_canaries.py)

This data lives ONLY with the scorer — it is never baked into the agent image
(the image ships train+dev arrow, but the scorer holds test refs). Run once:

    python3 prepare_test.py testdata/
"""
import os
import sys

from datasets import load_dataset


def _write_src(ds, path, lang):
    with open(path, "w") as f:
        for ex in ds:
            f.write(ex["translation"][lang].replace("\n", " ").strip() + "\n")


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "testdata"
    os.makedirs(out, exist_ok=True)

    test = load_dataset("wmt/wmt14", "de-en", split="test")
    src_p, ref_p = os.path.join(out, "test.src"), os.path.join(out, "test.ref")
    with open(src_p, "w") as fs, open(ref_p, "w") as fr:
        for ex in test:
            t = ex["translation"]
            fs.write(t["en"].replace("\n", " ").strip() + "\n")
            fr.write(t["de"].replace("\n", " ").strip() + "\n")
    print(f"wrote {test.num_rows} test pairs -> {src_p}, {ref_p}")

    dev = load_dataset("wmt/wmt14", "de-en", split="validation")
    dev_p = os.path.join(out, "dev.src")
    _write_src(dev, dev_p, "en")
    print(f"wrote {dev.num_rows} dev source lines -> {dev_p} (canary pool)")


if __name__ == "__main__":
    main()

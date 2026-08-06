#!/usr/bin/env python3
"""One-time, host-side, ONLINE. Fetch WMT14 de-en test (newstest2014) and write
test.src (English source) + test.ref (German reference).

This data lives ONLY with the scorer — it is never baked into the agent image
(the image ships train+dev only). Run once when standing up the bench:

    python3 prepare_test.py testdata/
"""
import os
import sys

from datasets import load_dataset


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "testdata"
    os.makedirs(out, exist_ok=True)
    ds = load_dataset("wmt/wmt14", "de-en", split="test")
    src_p, ref_p = os.path.join(out, "test.src"), os.path.join(out, "test.ref")
    with open(src_p, "w") as fs, open(ref_p, "w") as fr:
        for ex in ds:
            t = ex["translation"]
            fs.write(t["en"].replace("\n", " ").strip() + "\n")
            fr.write(t["de"].replace("\n", " ").strip() + "\n")
    print(f"wrote {ds.num_rows} test pairs -> {src_p}, {ref_p}")


if __name__ == "__main__":
    main()

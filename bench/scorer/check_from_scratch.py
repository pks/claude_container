#!/usr/bin/env python3
"""Advisory from-scratch provenance scan of a submitted artifact.

The REAL enforcement is the airgap: the run has no internet except its inference
endpoint, and the bench image ships no pretrained MT weights — so pretrained
weights can neither be downloaded nor are present to smuggle. This scan is a
light backstop that surfaces provenance red flags for a human to inspect. It is
ADVISORY: it prints flags and always exits 0; it never voids a run by itself.

    python3 check_from_scratch.py <artifact_dir>
"""
import glob
import json
import os
import sys


def main() -> None:
    art = sys.argv[1] if len(sys.argv) > 1 else "."
    flags = []

    # HF-style config that names a hub model (a from-scratch model has no such ref).
    for cfg in glob.glob(os.path.join(art, "**", "config.json"), recursive=True):
        try:
            c = json.load(open(cfg))
        except Exception:
            continue
        nop = str(c.get("_name_or_path", ""))
        if "/" in nop and not nop.startswith((".", "/")):
            flags.append(f"config _name_or_path looks like a hub model: {nop!r} ({cfg})")

    # markers of a downloaded/foreign checkpoint snapshot.
    for marker in ("**/*.msgpack", "**/*.h5", "**/pytorch_model.bin.index.json",
                   "**/model.safetensors.index.json", "**/.cache/huggingface"):
        for m in glob.glob(os.path.join(art, marker), recursive=True):
            flags.append(f"foreign-checkpoint marker: {m}")

    out = {
        "artifact": art,
        # the agent is asked to drop a from_scratch.json attestation (logged seed etc.)
        "from_scratch_attestation": os.path.exists(os.path.join(art, "from_scratch.json")),
        "provenance_flags": flags,
        "note": "advisory only; airgap + no-pretrained-in-image is the enforcement",
    }
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()

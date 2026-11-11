"""Re-parse every '--- custom:' block in dumps/*.txt with MAX's MLIR parser (parse + verify)."""
import glob
import re
import sys

import max.graph  # noqa: F401  registers dialects
from max import mlir
from max._mlir_context import default_mlir_context

ok = bad = 0
with default_mlir_context() as ctx:
    for path in sorted(glob.glob(os.path.join(DUMPS, "g*.txt"))):
        text = open(path).read()
        for chunk in text.split("=" * 100):
            m = re.search(r"### (.*)\n", chunk)
            if not m or "--- custom:" not in chunk:
                continue
            title = m.group(1)
            body = chunk.split("--- custom:\n", 1)[1].split("--- generic:")[0].strip()
            # strip the Graph.elm-irrelevant _kernel_library_paths? keep as is
            try:
                mod = mlir.Module.parse(body, ctx)
                ok += 1
            except Exception as e:
                bad += 1
                print("FAIL", path.split("/")[-1], "|", title, "|", str(e).split("\n")[0][:300])
print("parsed ok:", ok, "failed:", bad)

import sys, re
import max.graph
from max import mlir
from max._mlir_context import default_mlir_context
text = open(os.path.join(DUMPS, "g2_binary.txt")).read()
for chunk in text.split("="*100):
    if "### greater_equal f32" in chunk:
        body = chunk.split("--- custom:\n",1)[1].split("--- generic:")[0].strip()
        print(repr(body[-200:]))
        with default_mlir_context() as ctx:
            try: mlir.Module.parse(body, ctx)
            except Exception as e: print(e)

# Parse a hand-written mo text file in MAX's own MLIR context; write bytecode and generic text.
import sys
import max.graph  # registers the MAX dialects in the default context
from max import mlir
from max._mlir_context import default_mlir_context
src, bc, generic = sys.argv[1:4]
with default_mlir_context():
    m = mlir.Module.parse(open(src).read())
    with open(bc, "wb") as f:
        m.operation.write_bytecode(f)
    open(generic, "w").write(m.operation.get_asm(print_generic_op_form=True))
print("wrote", bc, generic)

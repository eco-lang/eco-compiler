"""Shared harness: build one tiny graph per case, record custom + generic IR (or the error)."""
import sys
import traceback

from max import mlir
from max.dtype import DType
from max.graph import DeviceRef, Graph, TensorType, ops  # noqa: F401
from max.graph.graph import _asm_via_cmlir

C = DeviceRef.CPU()
_counter = [0]


def T(dt, shape):
    return TensorType(dt, shape, device=C)


def generic(g):
    op = mlir.Operation._CAPICreate(g._module._CAPIPtr)
    return op.get_asm(print_generic_op_form=True)


def custom_module(g):
    return _asm_via_cmlir(g._module)


class Group:
    def __init__(self, path):
        self.path = path
        self.out = []

    def case(self, title, input_types, body, *, whole_module=False, want_generic=True):
        """body(g, *inputs) returns an output value or a tuple of them."""
        _counter[0] += 1
        name = "g%d" % _counter[0]
        self.out.append("=" * 100)
        self.out.append("### " + title)
        try:
            with Graph(name, input_types=input_types) as g:
                ins = [v.tensor if hasattr(v, "tensor") else v for v in g.inputs]
                res = body(g, *ins)
                if res is None:
                    res = ()
                if not isinstance(res, (tuple, list)):
                    res = (res,)
                g.output(*res)
            self.out.append("--- custom:")
            self.out.append(custom_module(g) if whole_module else str(g))
            if want_generic:
                self.out.append("--- generic:")
                self.out.append(generic(g))
        except Exception as e:  # record, don't guess
            self.out.append("--- ERROR: %s: %s" % (type(e).__name__, e))
            tb = traceback.format_exc().strip().split("\n")
            self.out.append("\n".join(tb[-6:]))

    def write(self):
        open(self.path, "w").write("\n".join(self.out) + "\n")
        print("wrote", self.path, file=sys.stderr)

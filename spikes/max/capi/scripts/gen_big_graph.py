"""Write a generic-form mo graph with N elementwise ops, to compare text and bytecode parse times.

    python3 gen_big_graph.py 20000 big.generic.mlir
    mlir-opt --allow-unregistered-dialect big.generic.mlir --emit-bytecode -o big.mlirbc
"""
import sys

n, path = int(sys.argv[1]), sys.argv[2]
t = "!mo.tensor<[batch, n], f32>"
lines = ['"builtin.module"() ({', '  "mo.graph"() ({', f"  ^bb0(%a: {t}, %b: {t}):"]
prev = "%a"
for i in range(n):
    op = "rmo.add" if i % 2 == 0 else "rmo.mul"
    lines.append(f'    %v{i} = "{op}"({prev}, %b) : ({t}, {t}) -> {t}')
    prev = f"%v{i}"
lines += [f'    "mo.output"({prev}) : ({t}) -> ()', '  }) {sym_name = "big"} : () -> ()', "}) : () -> ()"]
open(path, "w").write("\n".join(lines) + "\n")

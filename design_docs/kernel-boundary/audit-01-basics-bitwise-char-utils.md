# Kernel surface audit — Basics / Bitwise / Char / Utils (+ Order singletons)

Scope: every symbol declared in `elm-kernel-cpp/src/KernelExports.h` lines 25–77 (Basics),
83–89 (Bitwise), 95–104 (Char), 180–225 (Utils + Order). 84 symbols total.

**Method.** Implementations read in full:
`elm-kernel-cpp/src/core/{Basics,Bitwise,Char,Utils}.{hpp,cpp}` and
`{Basics,Bitwise,Char,Utils}Exports.cpp`; intrinsic coverage from
`compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`, op set from
`runtime/src/codegen/Ops.td`, actual lowering from
`runtime/src/codegen/Passes/EcoToLLVMArith.cpp`, symbol selection from
`compiler/src/Compiler/Generate/MLIR/KernelAbi.elm` + `Expr.elm`.

**Liveness evidence.** Exhaustive `grep -how` for all 80 `Elm_Kernel_*` symbols over the
990 generated `.mlir` files under `/work/build` (compiler self-compile
`compiler/build-kernel/bin/*.mlir` + the complete E2E corpus `test/*/eco-stuff/mlir/`).
Only **8** are ever referenced:

| symbol | occurrences |
|---|---|
| `Elm_Kernel_Utils_append` | 13660 |
| `Elm_Kernel_Utils_equal` | 5183 |
| `Elm_Kernel_Utils_compare` | 1208 |
| `Elm_Kernel_Utils_lt` | 324 |
| `Elm_Kernel_Utils_notEqual` | 250 |
| `Elm_Kernel_Utils_gt` | 164 |
| `Elm_Kernel_Char_toLower` | 16 |
| `Elm_Kernel_Utils_ge` | 12 |

The other 72 have **zero** references anywhere in the corpus.

**Notation.** "PAP-only dead" = the intrinsic always wins at applied call sites
(`Expr.elm:4199` tries `Intrinsics.kernelIntrinsic` *before* emitting a kernel call), so the
C++ body is reachable *only* when the kernel is referenced as a first-class value and captured
into a PAP (`Expr.elm:904` `instanceClosureResult` → `KernelAbi.elm:182` `kernelInstanceSymbol`).
Not deletable, but never on an applied path.

---

## Table

| Symbol | Signature | Class | HOF | Allocates | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| **Basics — transcendental** |
| `Elm_Kernel_Basics_acos` | `(f64)->f64` | P | no | no / no GC / no root | Already-intrinsic (`eco.float.acos`, Intrinsics.elm:422) — **PAP-only dead** | Lowers to a direct gc-leaf libm `acos` call (EcoToLLVMArith.cpp:357, EcoToLLVMRuntime.cpp:1060), *not* to this symbol. `Basics.cpp:16` = `std::acos`. Irreducible below "one libm call". |
| `Elm_Kernel_Basics_asin` | `(f64)->f64` | P | no | no | Already-intrinsic (`eco.float.asin`) — PAP-only dead | libm `asin`, gc-leaf. |
| `Elm_Kernel_Basics_atan` | `(f64)->f64` | P | no | no | Already-intrinsic (`eco.float.atan`) — PAP-only dead | libm `atan`, gc-leaf. |
| `Elm_Kernel_Basics_atan2` | `(f64,f64)->f64` | P | no | no | Already-intrinsic (`eco.float.atan2`) — PAP-only dead | libm `atan2`, gc-leaf. |
| `Elm_Kernel_Basics_cos` | `(f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | `LLVM::CosOp` (EcoToLLVMArith.cpp:313). Trivial once in LLVM. |
| `Elm_Kernel_Basics_sin` | `(f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | `LLVM::SinOp` (:302). |
| `Elm_Kernel_Basics_tan` | `(f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | ⚠ **divergence**: C++ `std::tan` (Basics.cpp:40) vs dialect `sin(x)/cos(x)` (EcoToLLVMArith.cpp:324-337). Different ULP/edge behaviour. |
| `Elm_Kernel_Basics_sqrt` | `(f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | `LLVM::SqrtOp` (:291). Trivial (1 instr). |
| `Elm_Kernel_Basics_log` | `(f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | `LLVM::LogOp` (:412). `Basics.logBase` is Elm-source over two `log`s. |
| **Basics — typed arithmetic** |
| `Elm_Kernel_Basics_add_Int` | `(i64,i64)->i64` | P | no | no | Already-intrinsic (`eco.int.add`→`arith.addi`) — PAP-only dead | Trivial, 1 instr. BasicsExports.cpp:123. |
| `Elm_Kernel_Basics_add_Float` | `(f64,f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. BasicsExports.cpp:127. |
| `Elm_Kernel_Basics_sub_Int` | `(i64,i64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Basics_sub_Float` | `(f64,f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Basics_mul_Int` | `(i64,i64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Basics_mul_Float` | `(f64,f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Basics_pow_Int` | `(i64,i64)->i64` | P | no | no | Already-intrinsic (`eco.int.pow`) — PAP-only dead, **but the intrinsic is still an opaque call** | `eco.int.pow` lowers to a call to `eco_int_pow` (EcoToLLVMArith.cpp:189-207 → EcoToLLVMRuntime.cpp:907, gc-leaf). `RuntimeExports.cpp:4560` is a byte-for-byte duplicate of `BasicsExports.cpp:149`. Feasible to inline as an LLVM loop; low value (gc-leaf already). |
| `Elm_Kernel_Basics_pow_Float` | `(f64,f64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | `LLVM::PowOp` (:280). |
| **Basics — boxed polymorphic roots** |
| `Elm_Kernel_Basics_add` | `(HPtr,HPtr)->HPtr` | **PA** (also PH) | no | **yes** — `alloc::allocInt`/`allocFloat` → `eco_alloc_with_roots` (HeapHelpers.hpp:319/332) / **can GC** / args are already unboxed i64/f64 before the alloc so **no stack root needed** | **Elm-source / compiler fix — should become deletable** | BasicsExports.cpp:95. Reads the heap tag of `a` (BasicsExports.cpp:70) and dispatches. Reached **only** when `kernelInstanceSymbol` sees `MVar` arg slots — but per `Monomorphized.elm:255-261` an `MVar _ CNumber` reaching MLIR codegen "is a compiler bug", and `MVar _ CEcoValue` cannot carry a `number`. So these 4 are a **safety net for a monomorphizer defect class**, not a real ABI path. 0 references in the corpus. ⚠ null-derefs if handed an embedded constant (`toPtr` returns nullptr). To eliminate: make `MVar _ CNumber` at a numeric kernel call site a hard compile error, then delete. |
| `Elm_Kernel_Basics_sub` | `(HPtr,HPtr)->HPtr` | PA | no | yes / GC / no root | same as `add` | BasicsExports.cpp:102. |
| `Elm_Kernel_Basics_mul` | `(HPtr,HPtr)->HPtr` | PA | no | yes / GC / no root | same as `add` | BasicsExports.cpp:109. |
| `Elm_Kernel_Basics_pow` | `(HPtr,HPtr)->HPtr` | PA | no | yes / GC / no root | same as `add` | BasicsExports.cpp:116. |
| **Basics — constants, division, rounding, predicates, booleans** |
| `Elm_Kernel_Basics_e` | `()->f64` | P | no | no | Already-intrinsic (`ConstantFloat`, Intrinsics.elm:352) — dead | Folded to `arith.constant 2.718281828459045` at both the applied and the var-reference site (`Expr.elm:776`). Trivial. |
| `Elm_Kernel_Basics_pi` | `()->f64` | P | no | no | Already-intrinsic — dead | `arith.constant 3.141592653589793`. Trivial. |
| `Elm_Kernel_Basics_fdiv` | `(f64,f64)->f64` | P | no | no | Already-intrinsic (`eco.float.div`→`arith.divf`) — PAP-only dead | Trivial. |
| `Elm_Kernel_Basics_idiv` | `(i64,i64)->i64` | P | no | no | Already-intrinsic (`eco.int.div`) — PAP-only dead | ⚠ **divergence**: `Basics.cpp:88` is bare `a / b` (**UB / SIGFPE** on `b==0`); the intrinsic guards and returns 0 (EcoToLLVMArith.cpp:57-81). Trivial (~4 instrs with the guard). |
| `Elm_Kernel_Basics_modBy` | `(i64,i64)->i64` | P (partial) | no | no | Already-intrinsic (`eco.int.modby`) — PAP-only dead | ⚠ **divergence**: `Basics.cpp:96` **throws `std::runtime_error`** on `modulus==0`; the intrinsic returns 0 (:83-131). A throw through JIT'd statepoint frames would terminate. Floored-modulo lowering is ~8 instrs. Trivial. |
| `Elm_Kernel_Basics_remainderBy` | `(i64,i64)->i64` | P | no | no | Already-intrinsic (`eco.int.remainderby`) — PAP-only dead | ⚠ same UB-on-zero divergence (`Basics.cpp:106` bare `x % divisor`). Trivial. |
| `Elm_Kernel_Basics_ceiling` | `(f64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | `llvm.ceil` + `fptosi` (:504). Trivial. |
| `Elm_Kernel_Basics_floor` | `(f64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | `llvm.floor` + `fptosi` (:488). Trivial. |
| `Elm_Kernel_Basics_round` | `(f64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | `llvm.round` + `fptosi` (:472). Trivial. |
| `Elm_Kernel_Basics_truncate` | `(f64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | `fptosi` alone (:520). Trivial, 1 instr. |
| `Elm_Kernel_Basics_toFloat` | `(i64)->f64` | P | no | no | Already-intrinsic — PAP-only dead | `arith.sitofp` (:459). Trivial, 1 instr. |
| `Elm_Kernel_Basics_isInfinite` | `(f64)->HPtr` | P | no | no (returns embedded `True`/`False` constant word) | Already-intrinsic — PAP-only dead | `fabs` + `fcmp oeq inf` (:436). Trivial. Intrinsic result is `i1`; kernel result is a boxed Bool HPtr — the intrinsic is strictly better (no box). |
| `Elm_Kernel_Basics_isNaN` | `(f64)->HPtr` | P | no | no | Already-intrinsic — PAP-only dead | `fcmp uno x, x` (:423). Trivial, 1 instr. |
| `Elm_Kernel_Basics_and` | `(HPtr,HPtr)->HPtr` | P | no | no | Already-intrinsic (`eco.bool.and`) — PAP-only dead | `decodeBoxedBool` is a bit test on the constant word (`ExportHelpers.hpp:85`), no heap read. Strict-in-both; `&&`/`||` short-circuit is rewritten to `If` in TypedOptimized (Intrinsics.elm:506-512), so this is only for first-class `(&&)`. Trivial. |
| `Elm_Kernel_Basics_or` | `(HPtr,HPtr)->HPtr` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Basics_xor` | `(HPtr,HPtr)->HPtr` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Basics_not` | `(HPtr)->HPtr` | P | no | no | Already-intrinsic — PAP-only dead | Trivial (1 xor). |
| **Bitwise (all 7)** |
| `Elm_Kernel_Bitwise_and` | `(i64,i64)->i64` | P | no | no | Already-intrinsic (`eco.int.and`→`arith.andi`) — PAP-only dead | Bitwise.cpp:5. Trivial, 1 instr. |
| `Elm_Kernel_Bitwise_or` | `(i64,i64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Bitwise_xor` | `(i64,i64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | Trivial. |
| `Elm_Kernel_Bitwise_complement` | `(i64)->i64` | P | no | no | Already-intrinsic — PAP-only dead | `xor -1` (EcoToLLVMArith.cpp:771). Trivial. |
| `Elm_Kernel_Bitwise_shiftLeftBy` | `(i64,i64)->i64` | P | no | no | Already-intrinsic (`eco.int.shl`) — PAP-only dead | Trivial. Arg order `(offset, a)`; the dialect op takes `(value, amount)` — the compiler feeds them in Elm order, verify if ever re-wired. |
| `Elm_Kernel_Bitwise_shiftRightBy` | `(i64,i64)->i64` | P | no | no | Already-intrinsic (`arith.shrsi`) — PAP-only dead | Trivial. |
| `Elm_Kernel_Bitwise_shiftRightZfBy` | `(i64,i64)->u64` | P | no | no | Already-intrinsic (`arith.shrui`) — PAP-only dead | Trivial. Kernel returns `uint64_t`, intrinsic `i64` — same bits. Both are 64-bit where stock Elm/JS is 32-bit; kernel and dialect agree with each other. |
| **Char (all 6)** |
| `Elm_Kernel_Char_fromCode` | `(i64)->u16` | P | no | no | Already-intrinsic (`eco.char.fromInt`) — PAP-only dead | `CharExports.cpp:11` clamps to `[0,0xFFFF]`; the intrinsic clamps identically (EcoToLLVMArith.cpp:888-912, max/min/trunc). **Trivial, 3 instrs.** ⚠ `Elm::Kernel::Char::fromCode` (Char.cpp:6) is **orphan dead code with different semantics** (returns U+FFFD out of range instead of clamping) — no callers anywhere. |
| `Elm_Kernel_Char_toCode` | `(u64)->i64` | P | no | no | Already-intrinsic (`eco.char.toInt`→`arith.extui`) — PAP-only dead | `CharExports.cpp:28`, mask `&0xFFFF`. **Trivial, 1 instr.** The `uint64_t` param width is the statepoint-zext workaround documented at CharExports.cpp:17-27; the intrinsic sidesteps it entirely by staying in i16. ⚠ `Char::toCode` (Char.cpp:38) is orphan dead code. |
| `Elm_Kernel_Char_toLower` | `(u64)->u16` | P | no | no | **Trivial — best new-intrinsic candidate in this group. LIVE (16 refs).** | **Table/library dependency: NONE.** `Char.cpp:76-80` is literally `if (c >= U'A' && c <= U'Z') return c + 32;` — an ASCII-only range test. No ICU, no libc `tolower`, no lookup table; every non-ASCII code point passes through unchanged (the `// TODO: Full Unicode case conversion requires ICU` at Char.cpp:79 is aspirational). Lowerable as `icmp uge / icmp ule / and / add / select` — 5 LLVM instructions. Today it is an opaque non-gc-leaf extern (see corpus sample `"eco.call"(%320) callee = @Elm_Kernel_Char_toLower : (i16)->i16`). |
| `Elm_Kernel_Char_toUpper` | `(u64)->u16` | P | no | no | **Trivial** (same shape) — 0 refs in corpus but reachable | `Char.cpp:98-102`: `if (c >= U'a' && c <= U'z') return c - 32;`. ASCII-only, no table. |
| `Elm_Kernel_Char_toLocaleLower` | `(u64)->u16` | P | no | no | **Trivial** — 0 refs | `Char.cpp:121` is a bare `return toLower(c);`. No locale, no ICU, no `setlocale`. Semantically identical to `toLower` today. |
| `Elm_Kernel_Char_toLocaleUpper` | `(u64)->u16` | P | no | no | **Trivial** — 0 refs | `Char.cpp:140` = `return toUpper(c);`. Identical to `toUpper`. |
| **Utils — typed comparison variants (21)** |
| `Elm_Kernel_Utils_compare_Int` | `(i64,i64)->HPtr` | P | no | no (returns pre-allocated singleton) | Already-intrinsic (`eco.int.cmp_order`) — PAP-only dead | UtilsExports.cpp:20. Intrinsic = 2 `icmp` + 2 `select` + 3 gc-leaf getter calls (EcoToLLVMArith.cpp:1008-1041). |
| `Elm_Kernel_Utils_compare_Float` | `(f64,f64)->HPtr` | P | no | no | Already-intrinsic (`eco.float.cmp_order`) — PAP-only dead | Ordered predicates route NaN→EQ; C++ `<`/`>` gives the same. |
| `Elm_Kernel_Utils_compare_Char` | `(u16,u16)->HPtr` | P | no | no | Already-intrinsic (`eco.char.cmp_order`) — PAP-only dead | Unsigned compares both sides. |
| `Elm_Kernel_Utils_equal_{Int,Float,Char}` | `(prim,prim)->HPtr` | P | no | no | Already-intrinsic (`eco.{int,float,char}.eq`) — PAP-only dead | UtilsExports.cpp:89-91. Trivial, 1 `cmp` + boxed-Bool constant. |
| `Elm_Kernel_Utils_notEqual_{Int,Float,Char}` | `(prim,prim)->HPtr` | P | no | no | Already-intrinsic (`.ne`) — PAP-only dead | UtilsExports.cpp:93-95. Trivial. |
| `Elm_Kernel_Utils_lt_{Int,Float,Char}` | `(prim,prim)->HPtr` | P | no | no | Already-intrinsic (`.lt`) — PAP-only dead | UtilsExports.cpp:97-99. Trivial. |
| `Elm_Kernel_Utils_le_{Int,Float,Char}` | `(prim,prim)->HPtr` | P | no | no | Already-intrinsic (`.le`) — PAP-only dead | UtilsExports.cpp:101-103. Trivial. |
| `Elm_Kernel_Utils_gt_{Int,Float,Char}` | `(prim,prim)->HPtr` | P | no | no | Already-intrinsic (`.gt`) — PAP-only dead | UtilsExports.cpp:105-107. Trivial. |
| `Elm_Kernel_Utils_ge_{Int,Float,Char}` | `(prim,prim)->HPtr` | P | no | no | Already-intrinsic (`.ge`) — PAP-only dead | UtilsExports.cpp:109-111. Trivial. |
| **Utils — boxed structural core (LIVE)** |
| `Elm_Kernel_Utils_compare` | `(HPtr,HPtr)->HPtr` | **PH** | no | **no GC allocation at all** (`Utils.cpp:451` returns one of the three rooted singletons; `StringOps::compare` only uses C++ `std::vector<SegView>`) / cannot GC / no stack root | **Split: primitives Already-intrinsic; Strings `Feasible` (new `eco.string.cmp_order`); everything else Hard/Infeasible** | `Utils.cpp:302-445`. **Irreducible part:** unbounded recursion/iteration over arbitrary heap values — per-slot 2-bit unboxed-kind bitmap dispatch (`tupleFieldKind`/`fieldKind`), mixed boxed-vs-unboxed primitive cross-checks (`compareUnboxableSlot`, :160-222), 4-form string representation via `StringOps::compare`, hybrid Cons/ConsChunk spines walked with `alloc::ListCursor` (`cmpListHybrid`, :285-299), Tuple2/3, and the arbitrary-depth tail. **Already-intrinsic part:** Int/Float/Char never reach here. ⚠ `assert(false)+__builtin_unreachable()` at :214-217 is UB under NDEBUG. |
| `Elm_Kernel_Utils_equal` | `(HPtr,HPtr)->HPtr` | **PH** (⚠ E on one path) | no | no GC allocation / cannot GC / no root | **Split: primitives Already-intrinsic; `("equal",[MString,MString])` → `Feasible` new `eco.string.eq` (highest-value new op); rest Hard/Infeasible** | `Utils.cpp:514-733` + guard `UtilsExports.cpp:47-58` (embedded constants compared by word, never through `toPtr`). Structural-recursion families: Tuple2/3, Cons/ConsChunk hybrid, Custom, Record, Array, ByteBuffer (3 forms), and **Dict-by-content** via `dictEq` (:746-796, dual-stack in-order LLRB walk with `std::vector<Custom*>`, colour deliberately ignored). ⚠ **`fprintf(stderr,...)` + `static int traceCount` at Utils.cpp:550-555** on tag mismatch — an observable side effect and a data race; that path is genuinely **E**. ⚠ `depth > 100` returns **`true`** (:560-562), i.e. deep values silently compare equal (`cmp` has no such limit — asymmetric). Also hard-wired into string-`case` lowering: every string pattern emits a call to this symbol (`EcoToLLVMControlFlow.cpp:412`). |
| `Elm_Kernel_Utils_notEqual` | `(HPtr,HPtr)->HPtr` | PH | no | no / cannot GC / no root | same as `equal` | `Utils.cpp:798`, `!equal(a,b)`. |
| `Elm_Kernel_Utils_lt` | `(HPtr,HPtr)->HPtr` | PH | no | no / cannot GC / no root | same split as `compare` | `Utils.cpp:802`, `cmp(a,b) < 0`. Thin wrapper — same irreducible core. |
| `Elm_Kernel_Utils_le` | `(HPtr,HPtr)->HPtr` | PH | no | no / cannot GC / no root | same split as `compare` | `Utils.cpp:806`. **0 references in the entire corpus** (the only boxed Utils comparison never emitted) — but structurally reachable for non-primitive `<=`. |
| `Elm_Kernel_Utils_gt` | `(HPtr,HPtr)->HPtr` | PH | no | no / cannot GC / no root | same split as `compare` | `Utils.cpp:810`. |
| `Elm_Kernel_Utils_ge` | `(HPtr,HPtr)->HPtr` | PH | no | no / cannot GC / no root | same split as `compare` | `Utils.cpp:814`. |
| `Elm_Kernel_Utils_append` | `(HPtr,HPtr)->HPtr` | **PA** (also PH) | no | **yes** — `StringOps::append` (leaf memcpy, `allocAsciiOut`, `allocString`, or `makeRope`) / `ListOps::append` (`listChunkChain` or `listFromUnboxables`) / **can GC** / **needs roots** (both callees root internally: `StringOps.hpp:497` `StackRootGuard`, `ListOps.cpp:274` `StackRootGuard`) | **`Feasible` — split into `eco.string.append` + `eco.list.append`. Highest-traffic symbol in the group (13660 refs).** | `Utils.cpp:822-846` does a **runtime tag dispatch** (`isString(a)&&isString(b)` → strings; `Tag_Cons`/`Tag_ConsChunk`/`isNil` → lists; otherwise silently returns `a`). The compiler already knows `MString` vs `MList` at the call site, so the dispatch is pure waste. The allocation itself (variable-length, rope/chunk construction) stays a runtime call — but it becomes a *typed* one and the silent "unsupported types → return a" fallback (:845) disappears. |
| **Order singletons / init** |
| `Eco_Runtime_getOrderLT` | `()->HPtr` | **RT** | no | no / cannot GC (already declared `gcLeaf=true`, EcoToLLVMRuntime.cpp:919) / no root | (n/a — RT) **Opportunity:** allocate the three Orders in permanent space and materialise their words as LLVM constants → `eco.*.cmp_order` becomes 2 cmp + 2 select with **zero calls** | `UtilsExports.cpp:135` → `Utils.cpp:47`. Reads the mutable global `ORDER_LT_SINGLETON`, which the GC rewrites in place (registered via `eco_gc_add_value_root`, Utils.cpp:41). Semantically idempotent/pure after init; classified RT because it reads GC-mutable runtime state. |
| `Eco_Runtime_getOrderEQ` | `()->HPtr` | RT | no | no / gc-leaf / no root | same | `UtilsExports.cpp:136`, `Utils.cpp:48`. |
| `Eco_Runtime_getOrderGT` | `()->HPtr` | RT | no | no / gc-leaf / no root | same | `UtilsExports.cpp:137`, `Utils.cpp:49`. |
| `Eco_Kernel_Order_register_gc_roots` | `()->void` | **RT** | no | **yes** (3× `alloc::custom`, Utils.cpp:35-40) / can GC / init-time only | (n/a) Keep — genuine one-time runtime init | `UtilsExports.cpp:139` → `Utils.cpp:33`. Idempotent via `ORDER_SINGLETONS_INITIALIZED`; mutates 3 globals and the GC value-root table. Called once per Elm thread from `ecoc.cpp:340`, `EcoRunner.cpp:241`, `eco_entry.cpp` (AOT). Not thread-safe (plain `bool` flag, no atomics). |

---

## Class counts

| Class | Count |
|---|---|
| **P** (pure, non-allocating) | 68 |
| **PA** (pure, allocates) | 5 — `Basics_{add,sub,mul,pow}` boxed roots + `Utils_append` |
| **PH** (pure, reads heap through HPtr args) | 7 — `Utils_{compare,equal,notEqual,lt,le,gt,ge}` |
| **RT** (runtime-internal state) | 4 — `Eco_Runtime_getOrder{LT,EQ,GT}` + `Eco_Kernel_Order_register_gc_roots` |
| **TB / E / X** | 0 |
| **HOF** | **0** — nothing in this group calls back into an Elm closure |
| **Total** | 84 |

---

## Key findings

1. **86% of this surface is dead C++ in practice.** Across 990 generated `.mlir` files (compiler
   self-compile + full E2E corpus), only 8 of the 80 `Elm_Kernel_*` symbols in scope are ever
   referenced. 72 have zero references.
2. **Intrinsics have already eaten Basics and Bitwise whole.** All 38 Basics symbols and all 7
   Bitwise symbols have zero references. `Intrinsics.elm:337-554` covers every one, and
   `Expr.elm:4199` tries the intrinsic *before* emitting a kernel call. They remain reachable only
   through a first-class reference captured into a PAP (`Expr.elm:904` `instanceClosureResult`) —
   which the HOF-elimination work has evidently driven to zero in this corpus.
3. **Char is 2/3 eaten and the remaining 1/3 is trivially eatable.** `fromCode`/`toCode` are
   intrinsics (`eco.char.fromInt`/`toInt`). The four case-mapping symbols depend on **no table and
   no library at all** — `Char.cpp:76` / `:98` are bare ASCII range tests, and
   `toLocaleLower`/`toLocaleUpper` (`Char.cpp:121`/`:140`) just forward to them. 5 LLVM
   instructions each.
4. **The genuinely irreducible core is exactly two things:** (a) `Utils::cmp`/`eqHelp` structural
   recursion over arbitrary heap values — per-slot unboxed-kind bitmap dispatch, mixed
   boxed/unboxed cross-checks, 4-form strings, hybrid Cons/ConsChunk spines, 3-form ByteBuffers,
   and content-based Dict equality (`dictEq`, `Utils.cpp:746`); and (b) `Utils::append`'s
   variable-length allocation (rope/chunk construction). Everything else is a 1–8 instruction
   sequence or a single libm call.
5. **`Utils.append` is the hottest symbol in the entire group by an order of magnitude** — 13660
   MLIR references, vs 5183 for `equal`. Its C++ body (`Utils.cpp:822-846`) re-derives at runtime
   the String-vs-List distinction the compiler already knows statically.
6. **`Utils` comparison kernels never allocate.** Verified end to end: `compare` returns a
   pre-allocated rooted singleton, `equal`/`lt`/… return embedded Bool constant words
   (`ExportHelpers.hpp:78`), `StringOps::equal`/`compare` are memcmp/segment walks with only C++
   `std::vector`, `dictEq` uses a C++ `std::vector<Custom*>`. **None of them can trigger GC.**
7. **…yet all of them are non-gc-leaf externs, so they poison GC-free propagation.**
   `propagateGcFreeLeafAttrs` (`EcoBackend.cpp:1627-1670`) marks any function calling a
   non-gc-leaf declaration as poisoned, and the poison propagates callee→caller. With ~19000
   `Utils_*` call sites, this is blocking the gc-free-function-propagation win on a large fraction
   of the compiler. Note the runtime *already* marks `eco_int_pow` and `Eco_Runtime_getOrder*`
   gc-leaf (`EcoToLLVMRuntime.cpp:907/919`) but explicitly does **not** for `Elm_Kernel_Utils_equal`
   (`:913`).
8. **The 4 boxed `Basics_{add,sub,mul,pow}` roots are a monomorphizer safety net, not an ABI path.**
   `kernelInstanceSymbol` (`KernelAbi.elm:282-304`) suffixes `_Int`/`_Float` whenever both arg
   MonoTypes are concrete; the root fires only on `MVar` slots, and `Monomorphized.elm:255-261`
   states that an `MVar _ CNumber` reaching codegen "is a compiler bug". To eliminate them: turn
   that condition into a hard compile error, then delete BasicsExports.cpp:64-121.
9. **Semantic divergences between the C++ bodies and their intrinsics** (latent, since the C++ is
   PAP-only reachable): `idiv` UB-on-zero vs intrinsic→0; `modBy` **throws `std::runtime_error`**
   (`Basics.cpp:96`) vs intrinsic→0; `remainderBy` UB-on-zero vs intrinsic→0; `tan` = `std::tan`
   vs `sin/cos`. A PAP-captured `modBy 0` and an inline `modBy 0` do different things today.
10. **Orphan dead code inside the module bodies:** `Elm::Kernel::Char::fromCode` (Char.cpp:6) and
    `::toCode` (Char.cpp:38) have **no callers at all** (CharExports.cpp implements both inline),
    and `fromCode`'s U+FFFD semantics contradict the clamping the export actually does.
    `Basics::add/sub/mul/pow` (the `double` overloads, Basics.cpp:52,72,76,80) are likewise unused —
    BasicsExports defines the typed variants inline.
11. **`Elm_Kernel_Utils_equal` has a real side effect.** `Utils.cpp:550-555` writes to `stderr`
    (first 10 occurrences) behind a non-atomic `static int` on the tag-mismatch path. That makes an
    otherwise-PH function E, is a data race, and emits stray diagnostics from shipped binaries.
12. **`eqHelp`'s `depth > 100 → return true`** (`Utils.cpp:560-562`) silently reports deep values as
    equal, while `cmp` has no depth limit — so `a == b` and `compare a b == EQ` can disagree.
13. **Nothing in this group is HOF.** No symbol calls back into an Elm closure, which means every
    one of them is a candidate for gc-leaf annotation on the allocation criterion alone.
14. **Code size is paid unconditionally.** `RuntimeSymbols.cpp:590-651` takes the address of every
    kernel symbol via `KERNEL_SYM`, pinning all 80 object-file bodies into `ecoc`/`ecor` regardless
    of use. Dead-in-corpus ≠ dead-in-binary.
15. **Top 3 opportunities** (see below).

### Top 3 opportunities

1. **Type-split `Utils.append` into `eco.string.append` / `eco.list.append`.** 13660 MLIR
   references — the hottest symbol here by 2.6×. Add
   `("append", [MString, MString])` / `("append", [MList _, MList _])` arms to
   `Intrinsics.elm:557` and lower each to a direct `StringOps::append` / `ListOps::append` shim.
   Removes a runtime tag dispatch (`Utils.cpp:827-845`) from the hottest kernel call in the
   compiler and deletes the silent "unsupported → return a" fallback.
2. **Mark the seven non-allocating boxed `Utils` comparisons + the four `Char` case-mappings
   gc-leaf.** All eleven provably cannot GC (finding 6). Today they are opaque externs that poison
   `propagateGcFreeLeafAttrs` (`EcoBackend.cpp:1627`) across ~19000 call sites and force RS4GC to
   statepoint every one. This is a one-line-per-symbol change in `EcoToLLVMRuntime.cpp` /
   the kernel-call declaration path, with no semantic risk, and it directly unblocks the
   gc-free-function-propagation series.
3. **Add `eco.string.eq` / `eco.string.cmp_order`, and constant-fold the Order singletons.**
   `Utils.equal` (5183 refs) and `Utils.compare` (1208) are dominated by String keys, and the
   string-`case` lowering already hardcodes a call to `Elm_Kernel_Utils_equal` per pattern
   (`EcoToLLVMControlFlow.cpp:412`). A String-typed op skips the whole `eqHelp` tag ladder.
   Separately, moving the three Order Customs into permanent space and emitting their words as LLVM
   constants turns every `eco.*.cmp_order` from "3 calls + 2 cmp + 2 select" into "2 cmp + 2 select".

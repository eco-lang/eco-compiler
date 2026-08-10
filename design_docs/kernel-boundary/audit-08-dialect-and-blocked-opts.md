# 08 — Eco Dialect Inventory & Optimizations Blocked by the Kernel Boundary

Audit date: 2026-08-09. Repo root `/work`. All paths absolute.

## Headline findings (read these first)

1. **There is NO LTO anywhere in the build.** An exhaustive grep for `-flto`,
   `ThinLTO`, `INTERPROCEDURAL_OPTIMIZATION`, `LTO` across every `CMakeLists.txt`,
   `*.cmake` and `CMakePresets.json` in the repo returns **zero** hits. The kernels
   are plain per-module `add_library(... STATIC ...)` archives
   (`/work/elm-kernel-cpp/CMakeLists.txt:33-80+`, `/work/eco-kernel-cpp/CMakeLists.txt`).
   Kernel bodies are therefore **invisible to LLVM at every point of the Eco
   pipeline**, even though they are C++ that LLVM itself compiled. The only
   "ThinLTO" references in the tree
   (`/work/runtime/src/codegen/EcoNativeDriver.h:41`,
   `/work/runtime/src/codegen/EcoBackend.cpp:499`,
   `/work/runtime/src/codegen/EcoBackend.h:196`) are describing the *lazy
   module-extraction pattern* used to parallelize Eco's own backend — not LTO.

2. **There is NO purity/effect metadata for kernel functions today.** The only
   per-kernel metadata table in the compiler is
   `/work/compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm` (33 entries),
   and its axis is **retention/aliasing, not purity**: it records
   `{ params : List ParamMode, resultAliases : List Int }` where
   `ParamMode = PBorrowed | POwned` (`KernelSigs.elm:35-53`). `Crash.crash`
   (which prints and `exit(1)`s) and `Debug.log` (which prints) are both in that
   table as `PBorrowed` — proof the axis is not effects. Everything else keyed by
   kernel name is ABI/arity/symbol-selection only. A purity classification must be
   built from scratch; `KernelSigs.elm` is the natural host, and it is already
   imported by exactly the two passes that would consume it.

   Worse, the two *ad hoc* effect judgements that do exist **contradict each
   other**. `isPureExpr` (`MonoInlineSimplify.elm:5114-5134`) says every kernel
   call — indeed every call — is impure, which blocks DCE. `CafHoist` /
   `CafDedupe` (`CafHoist.elm:392-393`) say every non-`Debug` kernel call is pure
   enough to hoist to a once-per-process CAF and to merge with an identical one.
   Both are shipping (the CAF passes default-off). Neither consults `KernelSigs`.

Consequence: the two facts compound. Without LTO, LLVM cannot *derive* purity; and
without a table, the compiler cannot *declare* it. Nothing in the pipeline knows
that `Elm_Kernel_String_length` cannot allocate, cannot write memory, and cannot
collect.

---

# SECTION A — DIALECT OP INVENTORY

## A.0 Where the dialect lives

| Artifact | File |
|---|---|
| Op / type / enum / interface definitions (TableGen) | `/work/runtime/src/codegen/Ops.td` (3,070 lines, **162 `def`s**) |
| Hand-written verifiers, GCRootCarrier impls, symbol-use checks | `/work/runtime/src/codegen/EcoOps.cpp` (55 KB) |
| Generated-header shim | `/work/runtime/src/codegen/EcoOps.h` (33 lines — pure `#include` of `eco/EcoOps.h.inc`) |
| Dialect registration | `/work/runtime/src/codegen/EcoDialect.{h,cpp}` (`EcoDialect::initialize()` at `EcoDialect.cpp:31-42`) |
| Type shims | `/work/runtime/src/codegen/EcoTypes.{h,cpp}` (`EcoTypes.cpp` is intentionally empty — the generated typedefs were moved into `EcoDialect.cpp:24`) |
| BF (ByteFusion) dialect | `/work/runtime/src/codegen/BF/BFOps.td` (20 KB, 27 ops) + `BF{Dialect,Ops,Types}.{h,cpp}` |
| BF lowering | `/work/runtime/src/codegen/Passes/BFToLLVM.cpp` |

**Everything is TableGen.** There is no hand-written op class. `EcoOps.h`,
`EcoTypes.h`, `EcoDialect.h` are three-line shims around `.inc` files.

## A.1 Types

`Ops.td:82-197` defines 7 dialect types:

| Type | Mnemonic | Meaning |
|---|---|---|
| `Eco_ValueType` | `!eco.value` | universal boxed heap value (HPointer) |
| `Eco_Tuple2Type` / `Eco_Tuple3Type` | `!eco.tuple2` / `!eco.tuple3` | SSA-level unboxed tuple aggregate |
| `Eco_RecordType` | `!eco.record` | SSA-level unboxed record aggregate |
| `Eco_CustomType` | `!eco.custom` | SSA-level unboxed custom-type aggregate |
| `Eco_ConsType` | `!eco.cons` | SSA-level unboxed cons cell |
| `Eco_ClosureEnvType` | `!eco.closure_env` | SSA-level closure environment |

Primitives ride builtin MLIR types (`Ops.td:239-242`): `Eco_Int = i64`,
`Eco_Float = f64`, `Eco_Char = i16`, `Eco_Bool = i1`.

## A.2 Op inventory by group — with lowering classification

Classification was produced by scanning every `*Lowering` pattern for uses of
`EcoRuntime::getOrCreate*` (the sole runtime-declaration factory,
`/work/runtime/src/codegen/Passes/EcoToLLVMInternal.h`, 149 distinct helpers).
`inline` = expands to pure LLVM IR with no call; `CALL` = emits an `llvm.call`.
`CALL→inline` = emits a **marker** call that a later LLVM-level prepass in
`EcoBackend.cpp` expands into open-coded IR (so the shipped code has no call).

### Group 1 — Integer arithmetic / bitwise (`Ops.td:1709-1866`, `2458-2560`)

`eco.int.{add,sub,mul,div,modby,remainderby,negate,abs,pow}`,
`eco.int.{and,or,xor,complement,shl,shr,shru}`.
Operands/results all `i64`. All `[Pure]`, `add/mul/and/or/xor` also `[Commutative]`.

Lowered by **`/work/runtime/src/codegen/Passes/EcoToLLVMArith.cpp`**. All **inline**
(`arith`/`LLVM` ops) **except** `eco.int.pow` → `CALL eco_int_pow`
(`EcoToLLVMArith.cpp:189-207`).

### Group 2 — Float arithmetic (`Ops.td:1868-2210`)

`eco.float.{add,sub,mul,div,negate,abs,pow,sqrt,sin,cos,tan,asin,acos,atan,atan2,log,isNaN,isInfinite}`,
`eco.int.toFloat`, `eco.float.{round,floor,ceiling,truncate}`. All `f64`→`f64`
(classify ops → `i1`, conversions `i64`↔`f64`). All `[Pure]`.

Lowered by `EcoToLLVMArith.cpp`. **inline** (`LLVM::FAddOp`, `LLVM::SqrtOp`,
`LLVM::SinOp`, `LLVM::CosOp`, `LLVM::LogOp`, `LLVM::FTruncOp`, …) **except**
`asin` / `acos` / `atan` / `atan2` → `CALL` to libm-style runtime helpers
(`EcoToLLVMArith.cpp:339-411`) — LLVM has no intrinsic for those.

### Group 3 — Comparison & ordering (`Ops.td:2217-2450`, `2623-2750`)

`eco.{int,float,char}.{lt,le,gt,ge,eq,ne}`, `eco.{int,float}.{min,max}`,
`eco.bool.{not,and,or,xor}`, `eco.char.{toInt,fromInt}`,
`eco.{int,float,char}.cmp_order`. All `[Pure]`; `eq`/`ne`/`min`/`max`/bool-and/or/xor
also `[Commutative]`.

Lowered by `EcoToLLVMArith.cpp`. All **inline** (`icmp`/`fcmp`/`select`) **except**
`eco.char.ne` and the three `cmp_order` ops, which `CALL`
`eco_get_order_{LT,EQ,GT}` to materialize the interned `Order` constants
(`EcoToLLVMArith.cpp:1014-1016`).

### Group 4 — Heap construction / allocation (`Ops.td:614-950`, `1409-1545`, `2960-3003`)

`eco.construct.{list,tuple2,tuple3,record,custom}`, `eco.allocate`,
`eco.allocate_ctor`, `eco.allocate_string`, `eco.allocate_closure`,
`eco.box`, `eco.to_heap`.
Results `!eco.value`. Construct ops are `[Pure]` + `GCRootCarrier`.

Lowered by **`/work/runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`** and
**`EcoToLLVMValueAgg.cpp`**. All **CALL** — but the shipped shape is a
**bump-pointer diamond**: the `_fast` path is the `__eco_alloc_inline(SIZE)`
marker, expanded to open-coded nursery bump IR by `expandInlineAllocs`
(`/work/runtime/src/codegen/EcoBackend.cpp:993-1119`); only the cold `_slow`
edge (`eco_alloc_inline_slow`) is a real, statepointed call. Field initialization
uses `eco_init_*_at` / `eco_store_*` helpers, ~92 of which are declared
`gcLeaf=true` (`/work/runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:126-152`).

### Group 5 — Heap field load (projection) (`Ops.td:648-696`, `757-949`, `3004-3033`)

`eco.project.{list_head,list_tail,tuple2,tuple3,record,custom,closure}`,
`eco.from_heap`, `eco.get_tag`, `eco.unbox`. All `[Pure]`.

Lowered by `EcoToLLVMHeap.cpp` / `EcoToLLVMValueAgg.cpp` / `EcoToLLVMControlFlow.cpp`.
`tuple2`/`tuple3`/`record`/`custom` projections and `unbox` are **inline** (resolve
+ GEP + load). `get_tag` and `list_head`/`list_tail` emit **markers**
(`__eco_get_tag_inline`, `__eco_list_head_inline`, `__eco_list_tail_inline`)
expanded inline by `expandGetTagMarkers` / `expandListProjMarkers`
(`EcoBackend.cpp:1412-1524`) — **CALL→inline**.

### Group 6 — Array ops (`Ops.td:950-1075`)

| Op | Operands → result | Lowering |
|---|---|---|
| `eco.array.length` | `!eco.value` → `i64` | **inline** (resolve + GEP + load i32 + zext), `EcoToLLVMHeap.cpp:1219-1250` |
| `eco.array.get` | `!eco.value, i64` → `!eco.value`/`i64`/`f64`/`i16` | **inline** (GEP + load), `EcoToLLVMHeap.cpp:1256-1305` |
| `eco.array.set` | `!eco.value, i64, elem` → `!eco.value` | **CALL** `eco_clone_array` + `eco_array_set_fix_kind`, then inline store |
| `eco.array.{empty,singleton,push,slice,append_n}` | | **CALL** |

Only `array.get`/`array.length` are `[Pure]`.

### Group 7 — String ops (`Ops.td:1076-1128`)

**Only three string ops exist in the dialect**: `eco.string_literal` (`[Pure]`),
`eco.string.from_int`, `eco.string.from_float`. The last two are **CALL**
(`eco_string_from_int`, and a region-alloc sequence for float,
`EcoToLLVMHeap.cpp:1525-1560`). **Every other string operation is a C++ kernel
call.** This is the single largest gap in the dialect.

### Group 8 — Control flow (`Ops.td:268-543`)

`eco.case` (regions), `eco.return`, `eco.yield`, `eco.joinpoint`, `eco.jump`,
`eco.crash` (terminator), `eco.expect`, `eco.dbg`.

Lowered in two stages: `EcoControlFlowToSCF.cpp` (eco → `scf`/`cf`), then
`EcoToLLVMControlFlow.cpp`. All **inline** except `eco.case` on string patterns,
which **CALLs `Elm_Kernel_Utils_equal`** — this is the one place the *lowering
itself* synthesizes a kernel call (`EcoControlFlowToSCF.cpp:748-833`,
`EcoToLLVMControlFlow.cpp:440-476`).

### Group 9 — Closures / calls (`Ops.td:1129-1408`, `3034+`)

`eco.call` (direct + indirect + `musttail`), `eco.papCreate`,
`eco.papCreateGroup`, `eco.papExtend`, `eco.make.closure`, `eco.project.closure`.
All carry `GCRootCarrier`. **`eco.call` is NOT `[Pure]` and declares NO
`MemoryEffects`** (`Ops.td:1129-1167`) — it is maximally effectful to MLIR.
`papCreate`/`papCreateGroup` *are* `[Pure]`.

Lowered by **`/work/runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`** (136 KB).
All **CALL**, with the closure-dispatch fast paths (`$cap` fast evaluators)
inlined by a pre-RS4GC prepass in `EcoBackend.cpp:1529-1610`.

### Group 10 — Globals / CAFs / type table (`Ops.td:1546-1615`, `544-581`)

`eco.global`, `eco.load_global`, `eco.store_global`, `eco.type_table`.
Lowered by `EcoToLLVMGlobals.cpp`; the first three are **inline** (LLVM globals +
load/store); `eco.type_table` **CALLs** `eco_register_type_graph` + `eco_gc_add_root`.

### Group 11 — SSA aggregate makers (`Ops.td:2862-2959`)

`eco.make.{tuple2,tuple3,record,custom,cons,closure_env}` — build an SSA-level
aggregate value, no heap. All `[Pure]`, all **inline** (`llvm.insertvalue`),
`EcoToLLVMValueAgg.cpp:100-197`.

### Group 12 — Reference counting (`Ops.td:2761-2860`) — DEAD

`eco.{incref,decref,decref_shallow,free,reset,reset_ref}`. These are **rejected
outright** by `/work/runtime/src/codegen/Passes/RCElimination.cpp:39-66`, which
emits `"eco.incref is not supported in tracing GC mode"` and fails the pass.
They exist as placeholders only.

### Group 13 — BF (ByteFusion) dialect — the precedent worth studying

`/work/runtime/src/codegen/BF/BFOps.td` — 27 ops, one type (`!bf.cursor`):
`bf.alloc`, `bf.cursor.{init,ptr}`, `bf.write.{u8,u16,u32,f32,f64,bytes,utf8,encoder}`,
`bf.read.{u8,i8,u16,i16,u32,i32,f32,f64,bytes,utf8}`, `bf.{utf8_width,bytes_width}`,
`bf.encoder.width`, `bf.require`, `bf.decoder.cursor.init`.

**BF is the existence proof for this whole review**: it is a dialect built
specifically to replace opaque `Elm_Kernel_Bytes_*` calls with typed, inline-lowered
ops. Notably, BF ops carry **explicit `MemoryEffects<[MemRead]>` / `MemoryEffects<[MemWrite]>`
traits** (`BFOps.td:94,146,215,249,264,279,303`) — the Eco dialect's kernel-facing
`eco.call` does not. Lowered by `/work/runtime/src/codegen/Passes/BFToLLVM.cpp`.

## A.3 What the dialect CAN express inline today

- **Integer & float arithmetic** — complete, except `int.pow` and 4 transcendentals.
- **Comparison & ordering on Int/Float/Char** — complete (modulo `Order`-constant materialization).
- **Bitwise & boolean** — complete.
- **Heap field LOAD** — complete and inline for every aggregate shape
  (tuple2/3, record, custom, cons head/tail, closure capture, array element).
- **Heap field STORE into a fresh object** — inline-ish (`eco_init_*_at`, gc-leaf).
- **Allocation** — inline bump-pointer fast path with a cold runtime slow edge.
- **Control flow** — full: multi-way `case` with regions, joinpoints, jumps,
  tail calls (`musttail`), crash terminators.
- **Closure creation & application** — full (`papCreate`/`papExtend`/`call`), with
  typed fast-evaluator dispatch.
- **SSA aggregates** — full, unboxed, no heap traffic.
- **Array indexing & length** — inline.
- **Type-tag interrogation** — inline (`get_tag` marker).

## A.4 What the dialect CANNOT express (the feasibility gap)

- **Strings — essentially everything.** Only `string_literal`, `from_int`,
  `from_float` exist. No `length`, `append`, `slice`, `uncons`, `cons`, `indexOf`,
  `toUpper`/`toLower`, `split`, `join`, `trim`, comparison, `fromChar`,
  char-at. All 31 `Elm_Kernel_String_*` exports are opaque calls.
  (String equality *is* reachable — via the hardcoded `Elm_Kernel_Utils_equal`
  call synthesized during case lowering.)
- **Structural equality / comparison on boxed values** — `Utils.equal`,
  `Utils.compare` on non-primitives are kernel calls; only the primitive
  `cmp_order` ops exist.
- **List operations** — no `eco.list.*` beyond construct/head/tail. `List.map`,
  `foldl`, `reverse`, `append`, `length` are all kernel calls. (Mitigated
  partially by `EcoListTemplate.cpp` and `EcoListCursor.cpp`, which
  *pattern-match* cons loops rather than provide ops.)
- **Array mutation without cloning** — `array.set` always clones.
- **Dict / Set / JSON / Regex / Bytes-decode / Time / Http / File / Process** —
  entirely kernel. (Bytes *encode* is covered by the BF dialect.)
- **Any notion of effects on a call.** `eco.call` has no memory-effect
  annotation and no purity attribute; there is no `eco.pure_call` variant.

## A.5 Cost of adding a NEW op

TableGen infrastructure is fully wired
(`/work/runtime/src/codegen/CMakeLists.txt:122-158`: `-gen-op-decls`,
`-gen-op-defs`, `-gen-op-interface-{decls,defs}`, `-gen-dialect-{decls,defs}`,
`-gen-typedef-{decls,defs}`, `-gen-enum-{decls,defs}` → target `EcoOpsIncGen`).

Minimum viable new op = **4 edits, no new files**:

1. **`/work/runtime/src/codegen/Ops.td`** — one `def Eco_FooOp : Eco_Op<"foo", [Pure]>`
   block with `arguments`/`results` (~15 lines). Traits are free here: `Pure`,
   `Commutative`, `MemoryEffects<[MemRead]>`, `DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>`.
2. **A lowering pattern** — one `struct FooOpLowering : OpConversionPattern<FooOp>`
   in the appropriate `EcoToLLVM*.cpp`, plus one line in that file's
   `populate…Patterns` list (e.g. `EcoToLLVMArith.cpp:1133`).
3. **Elm-side emission** — an `Intrinsic` constructor in
   `/work/compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` (add to `type Intrinsic`
   at `:26-53`, `intrinsicResultMlirType` at `:70+`, the per-module dispatch under
   `kernelIntrinsic` at `:312-334`, and `generateIntrinsicOp`).
4. **Nothing for MLIR bytecode.** The Elm-side writer is generic and string-keyed
   (`/work/compiler/src/Mlir/Mlir.elm:101-111` — `MlirOp` is `{ name : String, … }`;
   `/work/compiler/src/Mlir/Bytecode/StringTable.elm`). Op names are interned
   strings, so a new op needs no bytecode-format change.

Optional extras: a `hasVerifier = 1` + a `FooOp::verify()` in `EcoOps.cpp`; a
`GCRootCarrier` impl pair in `EcoOps.cpp:917-1040` if the op can allocate; an entry
in `EcoGCPrepare.cpp`'s `isMayAllocOp`/`hasFixedAllocSize`/`getFixedAllocSizeForGrouping`
(`:40-102`) if it allocates a fixed-size object.

**Verdict: adding an op is cheap** — roughly 60-120 lines across 3 existing files
for a pure, inline-lowered op. The expensive part is not the machinery; it is
(a) reimplementing the kernel's semantics in MLIR/LLVM IR, and (b) the byte-identity
self-host gate every codegen change must pass.

---

# SECTION B — OPTIMIZATIONS BLOCKED BY THE KERNEL BOUNDARY

## B.0 The pipeline, for reference

**MLIR passes** — `/work/runtime/src/codegen/EcoPipeline.cpp:49-134`, in order:
`RCElimination` → `EcoPAPSimplify` → `UndefinedFunction` → `JoinpointNormalization`
→ `EcoControlFlowToSCF` → `EcoListTemplate` → **`EcoGCPrepare`** → `BFToLLVM` →
`EcoToLLVM` → `EcoListCursor` → `SCFToControlFlow` → `ArithToLLVM` →
`ConvertControlFlowToLLVM` → `ReconcileUnrealizedCasts`.

> **There is no `createCSEPass()` and no `createCanonicalizerPass()` in the pipeline
> at all.** The one func-level canonicalizer was deliberately deleted
> (`EcoPipeline.cpp:80-90`, commented out with a measurement rationale). And **no
> op in `Ops.td` declares `hasFolder` or `hasCanonicalizer`** — a grep returns zero.
> So MLIR-level CSE and constant folding do not exist, for kernel calls *or*
> for the ~120 ops already marked `[Pure]`.

**Elm/Mono level** — `globalOptimizeWithStats`
(`/work/compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm:128`), driven from
`/work/compiler/src/Builder/Generate.elm:829`. Passes: `MonoInlineSimplify`,
`Staging`, `AbiCloning`, `CafHoist`/`CafCensus`/`CafDedupe`, `ListCombinators`,
`Borrow`. A pre-mono typed pass lives at `/work/compiler/src/Compiler/LocalOpt/Typed/`
(note: `pass_typed_optimization_theory.md:241-247` points at the stale path
`Compiler/Optimize/Typed/*`, which no longer exists).

**How a kernel call is represented in the mono IR.** There is **no dedicated
`KernelCall`/`Extern`/`Foreign` expression node.** A kernel call is an ordinary
`MonoCall` whose callee is a `MonoVarKernel` leaf
(`/work/compiler/src/Compiler/AST/Monomorphized.elm:1505-1512`):

```elm
    | MonoVarKernel Region Name Name Name MonoType -- kernel prefix, home, name, type
    | MonoCall Region MonoExpr (List MonoExpr) MonoType CallInfo
```

`MonoVarKernel` carries **a symbol reference, not a denotation** — `(prefix, home,
name, abiType)` and nothing else. A kernel-backed *spec* is `MonoExtern MonoType`
(`Monomorphized.elm:1461`), which has no body at all, so every body-walking pass
skips it.

**LLVM level** — AOT uses `CodeGenOptLevel::Aggressive` → `OptimizationLevel::O3`
(`/work/runtime/src/codegen/ecoc.cpp:265,310`; `EcoBackend.cpp:209-220`). Order is:
marker expansions → `$cap` inline prepass (`EcoBackend.cpp:1529-1610`) →
**`propagateGcFreeLeafAttrs`** (`:2560-2568`) → **RS4GC** (`:724-746`) →
`runCheapModuleIPO` (IPSCCP + GlobalOpt + GlobalDCE, `:228-259`) → module split →
per-partition `-O2`/`-O3` (`:288-300`). Everything after RS4GC operates on
already-statepointed IR.

---

## B.1 Inlining — kernel calls can never be inlined. CONFIRMED.

**Verified: no LTO.** Exhaustive grep for `-flto` / `ThinLTO` /
`INTERPROCEDURAL_OPTIMIZATION` / `LTO` across all `CMakeLists.txt`, `*.cmake`,
`CMakePresets.json`: **zero hits**. Kernels are per-module static archives:
`/work/elm-kernel-cpp/CMakeLists.txt` declares `ElmKernel_Basics`,
`ElmKernel_Bitwise`, `ElmKernel_Char`, `ElmKernel_String`, `ElmKernel_List`, … each
`add_library(... STATIC ...)` with `target_compile_features(... cxx_std_20)` and
nothing else. Same shape in `/work/eco-kernel-cpp/CMakeLists.txt`.

**And the MLIR side deliberately strips every attribute.** A kernel is emitted by
the Elm compiler as a `func.func` stub with `is_kernel = true`
(`/work/compiler/src/Compiler/Generate/MLIR/Functions.elm:1958-2006`). It is
lowered by `KernelFuncOpLowering`
(`/work/runtime/src/codegen/Passes/EcoToLLVMFunc.cpp:26-95`) to:

```cpp
auto llvmFunc = rewriter.create<LLVM::LLVMFuncOp>(loc, funcOp.getName(), llvmFuncType);
llvmFunc.setLinkage(LLVM::Linkage::External);
```

— a bare external declaration with **no body, no `memory(...)`, no `nounwind`, no
`willreturn`, no `gc-leaf-function`, no `speculatable`**. There is even an explicit
prohibition on adding purity attributes to runtime decls:
`/work/runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:888-889` —
*"Attrs are gc-leaf ONLY — do NOT add `memory(none)`/`speculatable`/`willreturn`"*.

**Net effect:** LLVM sees `declare ptr addrspace(1) @Elm_Kernel_String_length(ptr addrspace(1))`
with zero attributes. It must assume the call may read and write all memory, may
not return, may throw, may allocate, and may trigger GC. Every one of
inlining, CSE, LICM, store-to-load forwarding across the call, dead-store
elimination across the call, and DCE of an unused result is therefore blocked at
the LLVM level. **This is a headline finding: the kernel is C++ that LLVM
compiled, and LLVM is nonetheless blind to it.**

**Elm-side inlining is blocked for a different, structural reason.**
`MonoInlineSimplify` only fires on `MonoCall _ (MonoVarGlobal _ specId _) …`
(`/work/compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm:2460`); a
`MonoVarKernel` callee falls through to the generic "rewrite children" arm at
`:2544-2552`. There is no body to substitute. Two knock-on effects worth noting:

- `computeCost` scores `MonoVarKernel` at **1** (`MonoInlineSimplify.elm:1230`) —
  the cost model charges *nothing* for the unbounded C++ work behind the symbol,
  so any thin Elm wrapper around an expensive kernel looks maximally cheap and
  always inlines.
- The one place a kernel call *is* rewritten is partial-application merging
  (`MonoInlineSimplify.elm:3487-3506`), and it is legal only because the call is
  **strictly partial** (`List.length boundArgs < arity`) — a PAP is built and the
  C++ body has not run. The moment the call saturates, nothing can move it.

## B.2 GC safepoints / liveness — every kernel call is a full statepoint

**Yes, unconditionally.** Three mechanisms compound:

**(a) MLIR: full live-root sets are attached as extra SSA operands.**
`EcoGCPrepare` classifies `eco.call` as a call-safepoint
(`/work/runtime/src/codegen/Passes/EcoGCPrepare.cpp:125-140`, `isCallSafepoint`)
— only `musttail` calls are exempt. For each such op it computes the full set of
live `!eco.value` SSA values via MLIR's `Liveness` analysis
(`/work/runtime/src/codegen/Passes/EcoGCLiveness.h:33-70`, `computeLiveRoots`),
**unions it with the op's own `!eco.value` operands, and explicitly refuses to
shrink** (`EcoGCPrepare.cpp:315-351`). Those roots are then *appended as trailing
operands on the call itself* (`/work/runtime/src/codegen/EcoOps.cpp:989-1005`,
`CallOp::{get,set}GCRoots`, indexed by the `eco.gc_roots_count` attribute). So the
kernel boundary artificially **extends the live range of every live heap pointer
through the call, at the MLIR level, before LLVM ever sees it.**

**(b) MLIR: kernel calls break allocation grouping.**
`isGroupBarrier` (`EcoGCPrepare.cpp:110-121`) returns true for both `eco::CallOp`
and `func::CallOp` — comment: *"Any call-like op is a barrier (D3: conservative)"*.
A kernel call in the middle of a run of constructions splits what would have been
one coalesced bump allocation into two, doubling the capacity checks and the
statepoints.

**(c) LLVM: RS4GC statepoints it, and gc-free propagation cannot save it.**
The GC strategy is statepoint-based with RS4GC enabled
(`/work/runtime/src/codegen/Passes/EcoGCStrategy.cpp:20-27`: `UseStatepoints = true;
UseRS4GC = true;`), and GC-managed pointers are `addrspace(1)`. Since the kernel
declaration has no `gc-leaf-function`, RS4GC converts the call to a
`gc.statepoint` and every live `addrspace(1)` value becomes a gc-live operand —
spilled to the stack and reloaded through `gc.relocate` on the far side, plus a
stackmap record.

**The gc-free mechanism exists, is DEFAULT-ON, and explicitly excludes kernels.**
`propagateGcFreeLeafAttrs` (`/work/runtime/src/codegen/EcoBackend.cpp:1611-1726`)
stamps `gc-leaf-function` on generated functions that provably cannot GC, via an
optimistic reverse-worklist fixpoint. Mode selection at `EcoBackend.cpp:105-119`:

```cpp
const char *e = ::getenv("ECO_GCFREE_LEAF");
if (!e || !*e) return GcFreeMode::Stamp;   // default-ON since 2026-08-09
```

(`ECO_GCFREE_LEAF=0` = off; `=c` = census only. Companion `ECO_FP_LEAF` selective
frame pointers, also default-on, `EcoBackend.cpp:781-785`. Invariants
`CGEN_072`/`CGEN_073` at `/work/design_docs/invariants.csv:636-637`.)

The poison rule, verbatim (`EcoBackend.cpp:1651-1667`):

```cpp
if (llvm::callsGCLeafFunction(cb, TLI))
    continue;                        // RS4GC's own per-call-site predicate
Function *callee = cb->getCalledFunction();
if (callee && !callee->isDeclaration() && !callee->isInterposable()) {
    callers[callee].insert(&f);      // resolved by the fixpoint
    continue;
}
poison = true;                       // indirect call, or non-gc-leaf declaration
```

A kernel extern is a **declaration** without `gc-leaf-function`, so it hits
`poison = true` — and poison propagates **callee→caller to a fixed point**
(`:1676-1684`). **One kernel call anywhere in a call chain destroys GC-freeness for
every function above it.** `CGEN_072` states this explicitly:
*"…calls to non-gc-leaf declarations (… and ALL kernel externs) … are all poison."*

**Measured cost of the boundary, by proxy.** With gcfree stamping on,
2,372/44,967 functions (5.27%) qualify and **11,149 direct call sites lose their
statepoint** — worth **−1.74% wall, −2.06 MB `.text`, −5.17% stackmap bytes**, on
byte-identical allocation/minors/majors/output (`/work/benchmarks/tier2-opt.md:162-180`,
Run M). That 5.27% is the ceiling *given* that every kernel-calling function is
excluded. A kernel non-allocating allowlist is named as the obvious next lever and
is explicitly **unbuilt v2 work**: `/work/plans/gc-free-function-propagation.md:1268-1271`
— *"**KernelSigs non-allocating allowlist** → gc-leaf attrs on kernel decls at
translation. Audit bar is high: no transitive `alloc::` reach."*

## B.3 CSE / pure-call elimination — none exists, at any level

- **MLIR level: none.** No `createCSEPass()` anywhere in `/work/runtime/src/codegen/`;
  the sole canonicalizer is commented out (`EcoPipeline.cpp:90`). No op has
  `hasFolder`/`hasCanonicalizer`.
- **LLVM level: EarlyCSE/GVN run at `-O2`/`-O3`, but cannot touch kernel calls** —
  they only CSE calls to functions attributed `readnone`/`readonly`, and kernel
  declarations carry no attributes (§B.1).
- **Elm level: none.** `/work/plans/cse-pure-calls.md:24` states the premise
  outright: *"There is currently **no Elm-level CSE anywhere in the pipeline.**"*

**`plans/cse-pure-calls.md` status: PROPOSED, unimplemented, unsized.**
Line 3 verbatim: `**Status: NEW 2026-08-05, UNSIZED. Census (C1) before anything
else.**` No code exists (`ECO_CSE_REPORT` is not in `Config.elm`). The design is a
Mono-level (pre-MLIR) pass slotted into `globalOptimizeWithStats`
(`MonoGlobalOptimize.elm:128`) after inlining and before phase-5 call staging.

Critically, **it does not cover kernel calls, and says so** — carve-out 3,
`/work/plans/cse-pure-calls.md:82-86`:

> **Effectful kernels.** Not every `MonoVarKernel` is pure — `Task`/`IO`/port/
> scheduler primitives are not. CSE needs an explicit **purity classification of
> kernel names**, defaulting to *impure* for anything unlisted.

That classification does not exist (§B.6). The plan's own gate D-C requires
duplicates ≥2% of evaluated calls at bounded distance, and it notes the prior is
poor (*"the tier pattern is ×4 — static censuses of this shape have collapsed at
the admissibility gate four consecutive times"*, `:149-153`). Its named canary
risk is the `annotateCallStaging` O(2^let-depth) exponential.

**The two plans already point at each other**:
`/work/plans/gc-free-function-propagation.md:1275-1276` offers *"Feed the GC-free
set back to GlobalOpt as a purity oracle (plans/cse-pure-calls.md wants exactly
this fact)"* — a v2 item on both sides, built on neither.

**But a syntactic near-CSE of kernel calls already ships (default-off), with no
purity check at all.** Two CAF passes deduplicate *closed* subtrees by structural
equality, and both admit kernel calls:

- **`CafHoist`** (`/work/compiler/src/Compiler/GlobalOpt/CafHoist.elm:157, 314-360`)
  hoists any maximal closed subexpression into a once-per-process CAF.
  `candidateKind` (`:921-925`) admits **any** `MonoCall`, kernel calls included.
  Its entire effect model is one literal string comparison
  (`CafHoist.elm:392-393`):
  ```elm
        Mono.MonoVarKernel _ _ home _ _ ->
            ( { leafInfo | hasDebug = home == "Debug" }, [], ctx )
  ```
  The other exclusions (`skippedScalar` for `MInt`/`MFloat`/`MChar` via `valueAbi`
  `:958-975`, `skippedFnType` `:982`, bytes) are ABI/codegen-hazard filters, not
  semantic ones.
- **`CafDedupe`** (`/work/compiler/src/Compiler/GlobalOpt/CafDedupe.elm:67, 144-190`)
  merges structurally identical nullary specs by region-zeroed `==` (`:113-116`) —
  **no purity check whatsoever**. Two CAF specs whose bodies are the same kernel
  call are merged into one evaluation.

Both are default-off (`/work/compiler/src/Compiler/Eco/Config.elm:321`,
`hoist = { enabled = False, … }`). This is worth flagging on its own: the compiler
already *assumes* kernel purity in two passes, on the strength of
`home == "Debug"` — a much weaker basis than the classification a purity table
would provide, and in the opposite (unsound) direction from `isPureExpr`.

## B.4 RC elimination / borrow inference

**RC elimination is vestigial, not an optimization.** `RCElimination.cpp:39-66` is a
*verifier*: it walks the module and errors on any `eco.{incref,decref,decref_shallow,
free,reset,reset_ref}`, e.g. `"eco.incref is not supported in tracing GC mode"`.
`/work/design_docs/theory/pass_rc_elimination_theory.md:47-56` confirms the intent
("verification checkpoint"; RC ops are "Bug Indicators"). The runtime is a
generational **tracing** collector, so there is no RC to eliminate and the kernel
boundary blocks nothing here.

**Borrow inference is where the kernel boundary bites, and it is census-only.**
`/work/compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm` supplies per-kernel
`{ params : List ParamMode, resultAliases : List Int }` for **33** kernels
(`:54-167`). Two consumers:

- `/work/compiler/src/Compiler/GlobalOpt/Borrow/Constrain.elm:884` — the
  `MonoVarKernel` call arm calls `KernelSigs.lookup`; `:1078 applyKernelSig`,
  `:1101 applyKernelParams` map `PBorrowed` → `addSeedsOfRTy` and `POwned` →
  `ownEverything` + `escSeedAll`. **On a miss it calls `poisonArgs … RKernel`** and
  bumps `kernelDefaultedHeapCalls` / `kernelDefaultedNames`.
- `/work/compiler/src/Compiler/GlobalOpt/Borrow/LssFacts.elm:244` — same lookup for
  `Mono.OriginKernel`; **on a miss, `Poison PUnresolved`**.

So yes: **an unlisted kernel forces the maximally conservative "owned / escapes /
consumes" assumption**, by design (whitelist discipline, `KernelSigs.elm:14-16`).
The measured blast radius is in `/work/design_docs/borrow-inf-census.md:503`:
**`poisonedByKernel = 26,988` heap args poisoned at kernel calls**, with the
per-name histogram at `:845-870` (`List.cons=4151 Utils.append=3270
Scheduler.andThen=1625 Scheduler.succeed=907 Bytes.getStringWidth=696
Crash.crash=461 JsArray.foldl=322 …`). `:1060-1080` estimates ~2–3K recoverable
sites and flags *"kernel-allowlist growth is untracked as a deliverable"*.

Two further caveats: the whole oracle is **off by default**
(`/work/compiler/src/Compiler/Eco/Config.elm:323`:
`borrow = { enabled = False, reify = ROff, report = False, validate = False, oracleOpt = False }`),
and its output type `OracleFacts` (`Borrow/Facts.elm:35-46`) is keyed by
`SpecId`/LSS-member and currently has **no consumer** — `Generate/MLIR/Context.elm:242,316,353`
store it and nothing reads `borrowedParamsOf`.

## B.5 Constant folding — `String.length "abc"` and `sqrt 4.0` do NOT fold. Here is where each would.

- **`Basics.sqrt 4.0` — folds *almost* by accident, at LLVM.** `sqrt` is an
  intrinsic (`kernelIntrinsic` → `eco.float.sqrt`,
  `Intrinsics.elm:406`), lowered inline to `LLVM::SqrtOp`
  (`EcoToLLVMArith.cpp:291-300`). If the argument reaches it as an LLVM constant,
  InstCombine/ConstantFolding at `-O3` will fold it. **But nothing folds it earlier**:
  there is no MLIR folder (no `hasFolder` in `Ops.td`) and no Elm-level constant
  folder. So it survives as an op through the entire MLIR pipeline, is counted as
  live by `EcoGCPrepare`, and only collapses in the per-partition LLVM pipeline.
  Note `asin`/`acos`/`atan`/`atan2` are **runtime calls**, so those never fold.
- **`String.length "abc"` — cannot fold anywhere.** `String.length` is not in
  `kernelIntrinsic` (`Intrinsics.elm:312-334` dispatches only
  `Basics`/`Bitwise`/`Utils`/`JsArray`/`Char`/`String`, and the `String` arm covers
  only the few ops the dialect has). It emits `eco.call @Elm_Kernel_String_length`,
  which is not `[Pure]`, has no folder, and lowers to an attribute-free extern that
  LLVM must treat as arbitrarily effectful.

**There is no Elm-level constant folder at all.** A repo-wide grep for
`constFold` / `foldConstant` / `evalPrim` / `simplifyPrim` / `partial.?eval` over
`/work/compiler/src` finds exactly one hit, and it is unrelated:
`/work/compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm:134`
`simplifyWidth`, an integer-width arithmetic simplifier inside the bytes-fusion
loop IR (`WAdd (WConst a) (WConst b) -> WConst (a + b)`). It never touches Elm
expressions. The only literal-driven simplification in the whole mono pipeline is
**if-of-known-boolean** (`MonoInlineSimplify.elm:2578-2589`), which fires only when
the condition is *already* a `MonoLiteral (LBool …)` — and nothing ever produces a
literal from a kernel call, so a kernel-derived condition never reaches it. There
is likewise no case-of-known-constructor at the mono level
(`MonoInlineSimplify.elm:2612-2622` only recurses).

**Where folding would have to land**, in increasing order of leverage:
1. Elm/Mono level — a new phase in `MonoGlobalOptimize.elm`, needing a purity
   table + a compile-time evaluator for the kernel.
2. MLIR level — `let hasFolder = 1;` on the relevant `Ops.td` op + a `FooOp::fold`
   in `EcoOps.cpp`. Zero infrastructure cost; but requires the operation to *be* a
   dialect op, which for strings it is not (§A.4).
3. LLVM level — would require `memory(none) willreturn nounwind` on the kernel
   declaration (currently forbidden by policy, `EcoToLLVMRuntime.cpp:888-889`)
   *and* a body, i.e. LTO.

## B.6 Existing per-kernel effect/purity metadata: **none**

Exhaustive search of `compiler/src/` and `runtime/src/codegen/` for `isPure`,
`pureKernel`, `purity`, `effect`, `sideEffect`, `effectful`, `gcFree`, `gc_free`,
`mayAllocate`, `noalloc`, `allocates`, `canDuplicate`, `safeToDrop`, `observable`:
**zero hits** as metadata (only monadic `pure`/`IO.pure` combinators).

### B.6.1 The compiler's only effect judgement: `isPureExpr`

`/work/compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm:5099-5191`. Header
comment verbatim (`:5099-5101`): *"Check if an expression is pure (no side effects).
We're conservative here — only eliminate bindings we're certain are pure. Function
calls might have side effects (like Debug.log), so we don't eliminate them."*
The two arms that matter (`:5114-5115`, `:5132-5134`):

```elm
        MonoVarKernel _ _ _ _ _ ->
            -- Kernel functions could have side effects
            False
        ...
        MonoCall _ _ _ _ _ ->
            -- Function calls might have side effects
            False
```

Properties: it is a **two-valued blunt instrument**; it does **not** consult
`Borrow/KernelSigs.elm`; it does not distinguish `String.length` from
`Console.write`; and because `MonoCall -> False` is unconditional it also rejects
every *user* call. Even a bare kernel *reference* is impure, so taking a kernel's
address is un-droppable and un-relocatable. Its only two consumers are
`dropDeadDefs` (`:4780`) and the partial-forward guard (`:3477`, `:3499`).

**Consequence for DCE:** `dropDeadDefs` (`MonoInlineSimplify.elm:4744-4797`)
conservatively **keeps** unused kernel calls — `let _ = String.length s in body` is
never dropped. (Nor is any other call, of any kind.) There is no `isCheap`,
`canDuplicate`, or `isTrivial` predicate anywhere; the inliner never duplicates an
expression because `betaReduce`/`tryInlineCall` always let-bind arguments
(`:2952`, `:4663`), so the duplication question never arises.

**A second effect flag exists and is dead.** `specHasEffects : BitSet`
(`/work/compiler/src/Compiler/AST/Monomorphized.elm:1401`) is computed by
`nodeHasEffects` (`/work/compiler/src/Compiler/Monomorphize/Monomorphize.elm:582-611`),
which tests only `MonoVarKernel _ _ "Debug" _ _`. It has **no consumers** —
`MonoInlineSimplify.elm:902` explicitly discards it (`specHasEffects = BitSet.empty`),
confirmed by `/work/design_docs/theory/pass_global_optimization_theory.md:171`.

So the compiler's entire notion of "effect" is: (a) `isPureExpr`, which conflates
*all* calls with effects, and (b) a `Debug.*`-only bit that is computed and thrown
away. Meanwhile CafHoist/CafDedupe (§B.3) assume the *opposite* — that a non-`Debug`
kernel call is pure enough to hoist and dedupe. The two judgements are inconsistent.

### B.6.2 The metadata that does exist

What *does* exist, and its shape:

| Table | File:line | Shape | Entries | Axis |
|---|---|---|---|---|
| **`KernelSigs.table`** | `/work/compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm:35-53, 54-167` | `Dict (Name, Name) { params : List ParamMode, resultAliases : List Int }`, `ParamMode = PBorrowed \| POwned` | **33** | **retention/aliasing — NOT purity** |
| `suffixSelectingKernels` | `/work/compiler/src/Compiler/Monomorphize/KernelAbi.elm:145-192` | `EverySet (String, String)` | 18 | ABI symbol selection |
| `alwaysPolymorphicModules` | `.../Monomorphize/KernelAbi.elm:200-202` | `EverySet String` | 1 (`"Debug"`) | ABI |
| `kernelBackendAbiPolicy` | `/work/compiler/src/Compiler/Generate/MLIR/KernelAbi.elm:59-92` | `String -> String -> KernelBackendAbiPolicy` | constant `ElmDerived` (table retired) | ABI |
| `KernelTypeEnv` | `/work/compiler/src/Compiler/Type/KernelTypes.elm:43-44` | `Dict (Name, Name) (Can.Type Name)` | runtime-populated | types |
| `kernelIntrinsic` | `/work/compiler/src/Compiler/Generate/MLIR/Intrinsics.elm:312-334` | `Name -> Name -> List MonoType -> MonoType -> Maybe Intrinsic` | ~85 `Just` arms | which kernels bypass the call |
| `listShuntKernels` | `/work/compiler/src/Compiler/Generate/MLIR/Functions.elm:298-305` | `Dict Name Int` | 5 | chunked-list shunt |
| `defaultWhitelist` | `/work/compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm:951-1010` | `List String` (qualified Elm names) | ~45 | inline-cost bypass (Elm fns, not kernels) |
| runtime gc-leaf list | `/work/runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:126-152` | 92 `/*gcLeaf=*/true` of 146 `getOrCreateFunc` decls | 92 | GC-freeness of **runtime helpers**, zero kernels |
| `elm_kernel_functions.csv` | `/work/design_docs/elm_kernel_functions.csv` | CSV: `Package,Kernel Function` | 415 rows | **documentation only — no property columns** |

Two one-off purity assertions, both hand-written and non-tabular:

1. **`kernelDevirtArity`** — `/work/compiler/src/Compiler/MonoSolver/Translate.elm:1854-1868`,
   doc comment verbatim: *"Kernels have no annotation to arity-check against and may
   be effectful, so the whitelist is the soundness boundary: each entry must be pure
   (a plain allocator/value function) and pins its exact arity here."* The whitelist
   has **exactly one entry**: `List.cons → Just 2`.
2. **`KERNEL_TASK_IO_001`** — `/work/design_docs/invariants.csv:590` +
   `/work/design_docs/theory/kernel-task-deferral.md:86-105`. A **prose**
   classification naming pure Task constructors
   (`Elm_Kernel_Scheduler_{succeed,fail,andThen,onError,taskReceive}`),
   non-returning terminators (`Eco_Kernel_Process_exit`, `Eco_Kernel_Crash_crash`)
   and logging helpers (`Eco_Kernel_Console_log`). Enforced by **review**, not by any
   data structure — yet already load-bearing: CAF memoization cites it
   (`invariants.csv:359`, CGEN_068).

**Scale of the gap:** 387 distinct kernel exports across the two kernels
(`/work/elm-kernel-cpp/src/KernelExports.h`, `/work/eco-kernel-cpp/src/eco/KernelExports.h`),
with 33 classified for borrowing and 0 for purity. Largest modules:
Basics 38, Json 35, String 31, Utils 29, JsArray 29, Bytes 26, VirtualDom 25,
Eco.File 23, Browser 22, List 17.

**Where a purity classification would land:** `KernelSigs.elm` — extend `KernelSig`
with effect/allocation fields. It is already keyed `(home, name)` (matching
`KernelTypeEnv`), already imported by the two passes that need it, already has an
audit worklist with per-row C++ evidence anchors
(`/work/design_docs/borrow-inf-census.md:241-262` §3a, `:845-870` §15.2), and its
spec section (`/work/design_docs/globalopt/borrow-inference-design.md:1206-1258` §12)
is the natural place to document the new axis.

---

## B.7 Summary table — what the kernel boundary costs, per optimization

| Optimization | Level | Blocked by kernel call? | Mechanism |
|---|---|---|---|
| Function inlining | LLVM `-O3` | **Yes, absolutely** | No body in module; no LTO (§B.1) |
| Function inlining | Elm `MonoInlineSimplify` | **Yes** | Only fires on `MonoVarGlobal` callees (`:2460`); no body exists |
| Beta reduction | Elm | n/a | Kernel callee is never a `MonoClosure` |
| Partial-app merge | Elm `MonoInlineSimplify:3487-3506` | **Partially — the only kernel rewrite** | Legal only while strictly partial; guarded by `isPureExpr` on args |
| CSE of repeated calls | LLVM EarlyCSE/GVN | **Yes** | Decl has no `readnone`/`readonly` |
| CSE (MLIR) | — | n/a | No CSE pass exists at all |
| CSE (Elm/Mono) | — | n/a | Doesn't exist; `plans/cse-pure-calls.md` proposed, blocked on a purity table |
| Closed-subtree dedupe | `CafHoist`/`CafDedupe` | **No — but assumes purity unsoundly** | Effect model is `home == "Debug"` only; default-off |
| Constant folding | all three | **Yes** | No `hasFolder` in `Ops.td`; no Elm folder; no LLVM body |
| Case-of-known-ctor | Elm | n/a | Doesn't exist at mono level |
| DCE of unused let (Elm) | `dropDeadDefs:4744-4797` | **Yes — conservatively keeps** | `isPureExpr` returns `False` for every call |
| DCE of unused result | LLVM | **Yes** | Call may write memory / not return |
| LICM / hoisting out of loops | LLVM | **Yes** | Call may write memory |
| Store→load forwarding across call | LLVM | **Yes** | Call may write memory |
| GC statepoint elision | `propagateGcFreeLeafAttrs` | **Yes — poisons transitively** | `EcoBackend.cpp:1666`; `CGEN_072` |
| Selective frame pointers | `ECO_FP_LEAF` | **Yes** (follows statepoints) | `EcoBackend.cpp:768-828` |
| Capacity-check hoisting | `CGEN_074` | **Yes** (requires gcfree stamping) | `invariants.csv:638` |
| Allocation grouping | `EcoGCPrepare` | **Yes** | `isGroupBarrier`, `EcoGCPrepare.cpp:110-121` |
| Live-range shortening | `EcoGCPrepare` | **Yes** | Roots appended as call operands, `EcoOps.cpp:995-1005` |
| Borrow inference | Elm oracle | **Yes** | `poisonArgs … RKernel` on lookup miss; 26,988 poisoned args |
| LSS devirtualization | `MonoSolver/Translate.elm:1846-1890` | **Yes — whitelist of exactly 1** | *"Kernels have no annotation to arity-check against and may be effectful"*; only `List.cons` |
| List-combinator fusion | `ListCombinators.elm:222-247` | **Yes** | Recognizes elm/core **Elm** specs by registry origin; kernel calls invisible. Recognition-only today |
| Bytes fusion | `BytesFusion/Reify.elm:229,409-413,489` | **Works only by hardcoded name match** | Matches `"Bytes"`/`"List" "cons"` string literals; inliner must stand down (`MonoInlineSimplify.elm:944-947`) to preserve it |
| Staging / ABI segmentation | `Staging/Solver.elm:235-246` | **Kernel is an imposed fixed point** | `kernelSegForNode` short-circuits majority voting; user code eta-wraps to meet the kernel |
| Arity raising | `MonoInlineSimplify.elm:661-780` | **Yes** | Needs a `MonoClosure` body; kernel ABI arity is fixed. Default off |
| RC elimination | MLIR | n/a | Pass is a verifier; tracing GC, no RC exists |
| PAP simplification | `EcoPAPSimplify` | No | Operates on closure structure, kernel-agnostic |
| Tail-call conversion | `EcoTailConversions` | No | `musttail` calls are explicitly non-safepoints (`EcoGCPrepare.cpp:127-131`) |
| Joinpoint normalization | `JoinpointNormalization` | No | Structural |

## B.8 The recurring pattern

Three separate escape hatches exist for reasoning across the kernel boundary, and
all three have the same shape: **a human hand-transcribes one kernel's semantics
into an Elm table, with C++ file:line citations, one kernel at a time.**

1. `/work/compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm` — 33 entries,
   borrow/aliasing axis, each row anchored to a C++ export line.
2. `/work/compiler/src/Compiler/MonoSolver/Translate.elm:1852-1868` — **1 entry**
   (`List.cons`), purity+arity axis, whitelist is explicitly *"the soundness boundary"*.
3. `/work/compiler/src/Compiler/Generate/MLIR/Intrinsics.elm:312-334` — ~85 arms,
   "replace the call with a dialect op" axis.

Plus one prose classification enforced by review only
(`KERNEL_TASK_IO_001`, `/work/design_docs/invariants.csv:590`).

Against **387 kernel exports**. The BF dialect
(`/work/runtime/src/codegen/BF/BFOps.td`) is the one place the project chose the
other strategy — build typed ops with declared `MemoryEffects` and delete the
opaque calls entirely — and it is the only kernel family that fuses.

# CAF Memoization — Implementation Plan

Design: `design_docs/caf-memoization-design.md` (2026-07-22). Survey/evidence:
`/work/caf-survey.md`. Read `design_docs/invariants.csv` first — this touches
codegen + runtime lowering (REP_LLVM_001/002, CGEN_067 discipline, HEAP_030/033,
PORT_003).

**Goal.** Every qualifying nullary value thunk (`MonoDefine` non-closure,
`!eco.value` ABI result) evaluates **once per process**: its result is cached
in a per-SpecId `eco.global` slot and returned on every later call. Reference
sites are untouched (they keep calling the thunk). Slots are per emitted thunk
symbol — monomorphization splits one source CAF into several specialized
thunks (one per demanded type, more under LSS keying), and layouts differ per
spec, so slots are NEVER shared across SpecIds.

**Mechanism recap.** Elm backend emits `eco.global @__eco_caf$<funcName>` +
stamps the thunk's `func.func` with unit attr `eco.caf_memo`. The EcoToLLVM
pass (C++), in its serial post-Stage-2 phase, rewrites each tagged function:

```
entry:  %bits = load i64 from @slot
        cond_br (%bits != 0), ^hit, ^body
^hit:   return __eco_slot_to_hptr(%bits)          ; barrier, REP_LLVM_002
^body:  <original body>
        ; every llvm.return %r becomes:
        store __eco_hptr_to_slot(%r) to @slot ; return %r
```

Slot value `0` = uninitialized (no valid `!eco.value` word is 0: pointers are
nonzero addresses; embedded constants are 0x4/0x5/0x6). Rooting, GC
evacuation, init-function invocation, and partition splitting all ride the
existing `eco.global` machinery — verified in the design doc §DS6/§5.5:
minor GC updates JIT-root slots in place (`NurserySpace.cpp:638`
`evacuateJitPtr`), major GC marks them null/constant-safely
(`OldGenSpace.cpp:1576`), all four launch paths call `__eco_init_globals`
(`eco_entry.cpp:113`, `ecoc.cpp:343`, `EcoRunner.cpp:245`,
`eco_embed.cpp:193`), and `SplitModule PreserveLocals=false` externalizes
cross-partition eco.global cells (`EcoBackend.cpp:213` comment).

Semantics note (why this is sound): Elm is pure; once-evaluation differs
observably only in `Debug.log` count (converges with the JS backend, which
already evaluates top-level values once) and ⊥ timing (moves to first use —
still lazier than JS's load-time evaluation). Elm rejects top-level value
cycles, so lazy init cannot self-deadlock; benign dynamic re-entry
double-publishes structurally equal pure values (last-write-wins, sound).

---

## 1. Elm front-end changes

### 1.1 `compiler/src/Compiler/Eco/Config.elm` — the flag

Follow the `BytesFusionConfig` pattern exactly:

1. New alias + field:

```elm
{-| CAF memoization master switch (consumed by MLIR codegen —
plans/caf-memoization-implementation.md). `enabled = True` gives every
qualifying nullary value thunk a lazy once-init eco.global slot.
`ECO_CAF_MEMO=0` is the env escape (compile-time: the guard is baked into
generated code, so there is no runtime toggle).
-}
type alias CafMemoConfig =
    { enabled : Bool }
```

   Add `cafMemo : CafMemoConfig` to `EcoConfig` (after `logicalTypes`),
   export the alias from the module header.

2. `default`: `cafMemo = { enabled = True }` — **default ON**.

3. `decoder`: `|> D.apply (D.optionalField "cafMemo" cafMemoDecoder default.cafMemo)`
   with `cafMemoDecoder` mirroring `bytesFusionDecoder`. IMPORTANT: the
   `D.apply` chain order must match the `EcoConfig` field order (applicative
   decoding is positional).

4. `hash`: append token `"cafm=1"` **when enabled** (not when disabled).
   Rationale: enabling changes generated MLIR, so the new default must
   invalidate every pre-feature cache once; `ECO_CAF_MEMO=0` then hashes
   like the old world and can share old artifacts.

### 1.2 `compiler/src/Builder/Eco/Config.elm` — env escape

Add `ECO_CAF_MEMO` to `applyEnvOverrides` (append one more `Task.andThen`
step, copying the `applyLoopifyOverride` shape): value `0|false|no` (after
trim/lower) sets `cafMemo.enabled = False`; `1|true|yes` sets `True`; unset
or anything else leaves the config value. Document it in the module-doc
list. It runs before `hash` is taken, so it participates in cache keying
automatically.

### 1.3 `compiler/src/Compiler/Generate/MLIR/Ops.elm` — `ecoGlobal` builder

```elm
{-| eco.global - module-level GC-rooted value slot (CAF memoization).
Lowered to an internal i64 LLVM global initialized to 0; rooted at startup
by __eco_init_globals (EcoToLLVMGlobals.cpp).
-}
ecoGlobal : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
ecoGlobal ctx symName =
    mlirOp ctx "eco.global"
        |> opBuilder.withAttrs (Dict.fromList [ ( "sym_name", StringAttr symName ) ])
        |> opBuilder.build
```

`sym_name` as `StringAttr` matches `funcFunc`'s encoding of func symbols —
the writer already emits it in symbol position correctly. No results, no
operands, no regions (the `typeTableOp` precedent proves the writers handle
attr-only module-level ops). Export from Ops.elm.

### 1.4 `compiler/src/Compiler/Generate/MLIR/Functions.elm` — stamping

All edits in this file. The slot-name convention, used identically on the
C++ side: `cafSlotName funcName = "__eco_caf$" ++ funcName` (funcName embeds
the SpecId → per-spec slots by construction; `$` is legal in MLIR/LLVM
symbols — every thunk name already contains `_$_`).

(a) **Qualification predicate** (new top-level helper):

```elm
cafMemoQualifies : Ctx.Context -> Mono.MonoExpr -> Mono.MonoType -> Bool
cafMemoQualifies ctx expr monoType =
    ctx.ecoConfig.cafMemo.enabled
        && (Types.monoTypeToAbi monoType == Types.ecoValue)
        && not (monoTypeHasEffects monoType)
        && (case expr of
                Mono.MonoClosure _ _ _ ->
                    False   -- function definition, not a thunk (unreachable here, guard anyway)

                Mono.MonoLiteral _ _ ->
                    False   -- trivial: literal body

                Mono.MonoUnit ->
                    False   -- trivial: embedded Empty constant

                _ ->
                    True
           )
```

**Effect-type exclusion — REMOVED 2026-07-23** by
`plans/task-purity-and-caf-guard-removal.md` (kernel tasks are now fully
deferred and Task nodes immutable, so Task/Cmd/Sub CAFs memoize soundly;
`monoTypeHasEffects` deleted). Historical record of why it existed:
`monoTypeHasEffects` walks
the mono type and returns True for `Platform.Task`/`ProcessId`/`Router`/
`Program`, `Platform.Cmd.Cmd`, `Platform.Sub.Sub` — recursing through
`MList`/`MTuple`/`MRecord` and `MCustom` instantiation args, with
`MFunction` as a barrier. Rationale (native-runtime facts, not Elm
semantics): the scheduler mutates Task nodes in place (`Scheduler.cpp:853`,
one-shot kill-handle install), and native kernel task VALUES can be EAGER —
`Eco_Kernel_MVar_new()` allocates the MVar id at value-evaluation time and
returns `Task_Succeed id` (`MVarExports.cpp:13`), so the per-reference
thunk call was load-bearing: caching made a second `MVar.new` return the
first (dropped) id. See `plans/defer-eager-kernel-tasks-via-binding.md`
for the kernel-side class; if that lands and the scheduler mutation goes,
this exclusion can be revisited. Needs `import System.TypeCheck.IO as IO`
in Functions.elm for the `IO.Canonical` match.

Notes: the ABI check (`!eco.value` result only) is the v1 scope from the
design (DS5): scalar-ABI thunks (i64/f64/i16) are *excluded* — the
`createGlobalRootInitFunction` walk roots every internal i64 global, and a
raw Int in a rooted slot would be misread by the GC as a heap address.
Bool CAFs are covered (Bool is `!eco.value` at ABI, and True/False embedded
constants are nonzero). `MonoLiteral` covers `LStr` too — a lone
string-literal body is already interned per-call; skip it.

(b) **`generateDefine`** (line ~408): add a `cafMemo : Bool` parameter
(threaded from the caller — see (c)); in the *thunk arm* (the `_ ->` branch,
"Value (thunk) - wrap in nullary function"), when
`cafMemo && cafMemoQualifies ctx expr monoType`:

```elm
let
    ( ctxG, globalOp ) =
        Ops.ecoGlobal ctx2 (cafSlotName funcName)

    funcOpTagged =
        { funcOp | attrs = Dict.insert "eco.caf_memo" UnitAttr funcOp.attrs }
in
( [ globalOp, funcOpTagged ], ctxG )
```

(`UnitAttr` is imported from `Mlir.Mlir` already — the
`addShadowRootsAttr` precedent at line 395.) When not qualifying, behavior
is byte-identical to today.

(c) **Call sites of `generateDefine`** (`generateNodeInner`, line ~313):

- `Mono.MonoDefine expr monoType ->` pass `cafMemo = True`.
- `Mono.MonoPortIncoming` / `Mono.MonoPortOutgoing` arms pass
  `cafMemo = False` (PORT_003: port nodes stay untouched; port *decoder*
  specs are plain `MonoDefine`s and memoize normally — that is safe and
  intended).

(d) **Main-entry strip** (`generateNode`, line ~276): `main` is itself a
`MonoDefine` thunk AND is tagged `eco.shadow_roots`. A guard's hit-path
early return would skip the shadow-root frame push while the epilogue pops
— unbalanced. Strip it Elm-side where `isMainEntry` is already computed:

```elm
finalOps =
    if isMainEntry then
        List.map addShadowRootsAttr ops
            |> List.filter (\op -> op.name /= "eco.global")
            |> List.map (\op -> { op | attrs = Dict.remove "eco.caf_memo" op.attrs })
    else
        ops
```

The C++ side ALSO skips any caf-tagged func that carries `eco.shadow_roots`
(§2.3) — belt and braces; either alone is sufficient.

Emission-path coverage: `generateNode` feeds all three module writers
(`generateMlirModule`, `streamMlirToWriter`, `streamMlirBytecode` in
Backend.elm) — nothing else to touch. The `eco.global` op travels inside the
node's op chunk into the module body next to its thunk.

## 2. C++ backend changes (runtime/src/codegen)

### 2.1 Pre-scan — `Passes/EcoToLLVM.cpp` (~line 200)

Extend the existing pre-Stage-0 walk (which already collects
`eco.shadow_roots` names — func::FuncOps are erased by conversion, so
attrs must be read up front):

```cpp
llvm::DenseSet<llvm::StringRef> cafMemoFuncs;
module.walk([&](func::FuncOp funcOp) {
    runtime.origFuncTypes[funcOp.getSymName()] = funcOp.getFunctionType();
    if (funcOp->hasAttr("eco.shadow_roots"))
        shadowRootFuncs.insert(funcOp.getSymName());
    if (funcOp->hasAttr("eco.caf_memo"))
        cafMemoFuncs.insert(funcOp.getSymName());
});
```

### 2.2 Guard installer — `Passes/EcoToLLVMGlobals.cpp`

New function, declared in `Passes/EcoToLLVMInternal.h` next to
`createGlobalRootInitFunction`:

```cpp
/// CAF memoization (plans/caf-memoization-implementation.md): wrap a nullary
/// thunk in a load-check-return / store-on-return guard against its
/// `__eco_caf$<name>` slot. Runs in the serial post-Stage-2 phase, BEFORE
/// createGlobalRootInitFunction (which then roots the slot) and before the
/// unused-decl strip (so the barrier decls it references stay live).
void installCafMemoGuard(mlir::LLVM::LLVMFuncOp func);
```

Implementation (all builders `OpBuilder`; barrier helpers + symbol names
from `EcoToLLVMInternal.h` / `EcoSlotCastBarriers.h`, whose declarations are
pre-materialized unconditionally by `materializeAllRuntimeDecls`):

```cpp
void eco::detail::installCafMemoGuard(LLVM::LLVMFuncOp func) {
    if (func.isExternal()) return;
    auto *ctx = func.getContext();
    auto loc  = func.getLoc();
    Region &body = func.getBody();
    Block *oldEntry = &body.front();

    // Sanity: nullary thunk returning ptr addrspace(1) (converted !eco.value).
    auto fnTy = func.getFunctionType();
    auto ptr1Ty = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);
    if (fnTy.getNumParams() != 0 || fnTy.getReturnType() != ptr1Ty) {
        func.emitError("eco.caf_memo on a non-thunk or non-!eco.value function");
        return;   // signalPassFailure at the caller via walk result if desired
    }

    std::string slotName = ("__eco_caf$" + func.getSymName()).str();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    OpBuilder b(ctx);

    // 1. Instrument every existing return FIRST (so the hit-path return added
    //    below is not instrumented). No statepoint between store and return —
    //    the CGEN_067 discipline.
    SmallVector<LLVM::ReturnOp> rets;
    body.walk([&](LLVM::ReturnOp r) { rets.push_back(r); });
    for (LLVM::ReturnOp r : rets) {
        b.setInsertionPoint(r);
        Value addr = b.create<LLVM::AddressOfOp>(loc, ptrTy, slotName);
        Value bits = globalStoreValueToI64(b, loc, r.getOperand(0)); // __eco_hptr_to_slot
        b.create<LLVM::StoreOp>(loc, bits, addr);
    }

    // 2. New entry + hit blocks. Thunk has no params, so the new entry block
    //    needs no arguments.
    Block *entry = new Block();
    body.push_front(entry);                       // becomes the entry block
    Block *hit = new Block();
    body.getBlocks().insertAfter(entry->getIterator(), hit); // any position works

    b.setInsertionPointToEnd(entry);
    Value addr  = b.create<LLVM::AddressOfOp>(loc, ptrTy, slotName);
    Value bits  = b.create<LLVM::LoadOp>(loc, i64Ty, addr);
    Value zero  = b.create<LLVM::ConstantOp>(loc, i64Ty, b.getI64IntegerAttr(0));
    Value isSet = b.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, bits, zero);
    b.create<LLVM::CondBrOp>(loc, isSet, hit, oldEntry);

    b.setInsertionPointToEnd(hit);
    Value v = globalLoadI64ToValue(b, loc, bits);   // __eco_slot_to_hptr barrier
    b.create<LLVM::ReturnOp>(loc, v);
}
```

Correctness notes for the reviewer:

- `globalLoadI64ToValue`/`globalStoreValueToI64` are the same fold-proof
  slot-cast barrier forms the `eco.load_global`/`store_global` lowerings
  use (REP_LLVM_001(c) global-boundary crossing, REP_LLVM_002 barriers,
  stripped post-RS4GC by `StripEcoCastBarriers`). With
  `ECO_SLOT_CAST_BARRIERS=0` they fall back to bare casts and the `$cap`
  prepass re-tightens its guard — no extra handling needed here.
- `%bits` is used only in `entry`/`hit` (no statepoint on that path);
  the store is immediately before its return. No i64 with pointer
  provenance is live across any statepoint.
- `llvm.unreachable`/crash tails have no ReturnOp — untouched.
- The slot symbol resolves because the Elm side emitted `eco.global` with
  the same name and Stage 0 lowered it to an `llvm.mlir.global`
  (`GlobalOpLowering`) before this runs.

### 2.3 Wiring — `Passes/EcoToLLVM.cpp` stage-4 walk (~line 507)

Extend the existing fused post-conversion walk:

```cpp
module.walk([&](LLVM::LLVMFuncOp func) {
    if (func.isExternal())
        return;
    if (!func.getGarbageCollector())
        func.setGarbageCollector("eco-gc");
    if (!cafMemoFuncs.empty() &&
        cafMemoFuncs.contains(func.getSymName()) &&
        !shadowRootFuncs.contains(func.getSymName())) {   // main: see plan §1.4(d)
        installCafMemoGuard(func);
    }
    if (!shadowRootFuncs.empty() && shadowRootFuncs.contains(func.getSymName())) {
        ... existing shadow-root installation unchanged ...
    }
});
```

Ordering guarantees (all already satisfied by the insertion point):
- AFTER Stage 2 body conversion (returns are uniform `llvm.return`s — both
  thunk shapes, single-return and terminated-multi-return, handled the same).
- BEFORE `createGlobalRootInitFunction` (line ~527) — slots get rooted.
- BEFORE the unused-decl strip — the barrier decls the guard references are
  seen as used.
- BEFORE MLIR→LLVM-IR translation, hence before the `$cap` inline prepass
  and every RS4GC flavour — anything that later inlines a thunk copies the
  guard along.
- Serial phase (`runtime.frozen = false` zone) — no parallel-mutation issues;
  the `ECO_ECO2LLVM_PARALLEL` byte-identical property is untouched because
  this runs outside the parallel chunk loop, in walk (deterministic) order.

No changes to `createGlobalRootInitFunction`, the runtime, the allocator, or
any launch path: v1 slots are exactly the internal-i64 globals its walk
already collects and roots.

## 3. Codegen test fixtures — `test/codegen/`

Auto-discovered by `CodegenIsolatedTest::buildCodegenTestSuite()` (directory
scan) — just add files. Copy the `// RUN: %ecoc %s -emit=jit 2>&1 |
%FileCheck %s` header from `global_basic.mlir`. Before writing, crib exact
op syntax (eco.call textual form, dbg, box/unbox) from existing fixtures
(`global_basic.mlir`, any fixture calling a private func.func).

**`caf_memo_basic.mlir`** — memoize-once + cached value identity:

```mlir
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// CAF memoization: tagged thunk body runs once; 2nd call returns the cache.
module {
  eco.global @"__eco_caf$make_val"

  func.func private @make_val() -> !eco.value attributes { eco.caf_memo } {
    %c = arith.constant 111 : i64
    eco.dbg %c : i64                          // proves single evaluation
    %sum = arith.constant 7 : i64
    %v = eco.box %sum : i64 -> !eco.value
    eco.return %v : !eco.value
  }

  func.func @main() -> i64 {
    %a = ... call @make_val ...               // eco call syntax per existing fixtures
    %ua = eco.unbox %a : !eco.value -> i64
    eco.dbg %ua : i64
    %b = ... call @make_val ...
    %ub = eco.unbox %b : !eco.value -> i64
    eco.dbg %ub : i64
    %z = arith.constant 0 : i64
    return %z : i64
  }
}
// CHECK: 111
// CHECK-NEXT: 7
// CHECK-NEXT: 7
```

(`CHECK-NEXT` after the single `111` proves the body did not re-run.)

**`caf_memo_gc.mlir`** — value survives GC via the rooted slot: thunk
allocates a tuple; main calls it, forces a minor+major GC (crib the
GC-forcing extern decl pattern from existing fixtures — grep
`test/codegen` for `eco_minor_gc` / `major`; if no fixture precedent
exists, declare `func.func private @eco_major_gc()` extern and call it —
the symbol is exported by RuntimeSymbols), calls again, projects fields
from the second result. Checks: field values correct after GC, body-dbg
printed once.

**`caf_memo_multiret.mlir`** — a tagged thunk with two returns (branch on a
constant via `cf.cond_br` or `scf.if` + eco.return per arm, matching
whichever control-flow idiom existing fixtures use) — proves every return
publishes; call twice, expect one body-dbg.

Also EXTEND `global_basic.mlir`? No — leave existing fixtures untouched.

## 4. Build + test validation sequence

```bash
# 1. Build + full E2E (compiler rebuild + fixtures + corpus). ONCE, teed:
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
# then grep /tmp/test_output.txt — do NOT rerun on failure without a fix.
```

- Expect the three new fixtures in the codegen count (388 → 391) and the
  E2E corpus green. Front-end unit tests: `cmake --build build --target
  elm-tests 2>&1 | tee /tmp/elm_test_output.txt`.
- Invariant-test exposure: `Backend.generateMlirModule` (invariant-testing
  entry) uses `Config.default` → cafMemo ON inside `compiler/tests`. If a
  SourceIR/invariant test asserts an exact op population (e.g. "module
  contains only func.func"), it will now see `eco.global` ops / the extra
  attr. Fix forward: adjust the test's expectation, or pin
  `cafMemo = { enabled = False }` in that test's config the way
  TestPipeline pins LSS — prefer expectation updates when the test is
  *about* module shape, pins when it is about something else entirely.
- JIT E2E harness heap resets: no new machinery — slots are per-module
  globals, re-zeroed by each test's fresh module; roots die with the
  harness heap reset (the existing `global_*.mlir` lifecycle).
- Debug-tool sanity (optional): `ECO_CAF_MEMO=0` build of one E2E test
  must be byte-identical to pre-change output (flag-off = old world).

Known traps (from memory/plans — check before debugging "mysteries"):
- `--target full`, never `check`, after Elm changes (stale .mlir).
- Running build/test/test and elm-tests CONCURRENTLY corrupts ~/.eco —
  run serially.
- `ECO_LOWERING_VALIDATION` is a compile-time #ifdef; an env-only verifier
  run is vacuous. The EcoPtrIntVerify leg needs the validation build if
  exercised; for this plan the default build + fixtures suffice (the
  barrier forms used are the audited P2.5/R5 ones).

## 5. Full bootstrap

```bash
cmake --build build --target bootstrap 2>&1 | tee /tmp/bootstrap_output.txt
```

Chain: Stage 4a JS self-compile → 4b JS fixed point (eco-boot-2.js ==
eco-boot-3.js) → Stage 5 (eco-boot-2.js emits eco-compiler.mlir, node 12 GiB)
→ Stage 6 (native eco-compiler) → 7a (self-compile → eco-compiler-boot.mlir)
→ 7b (native eco-compiler-boot) → 8a/8b (second generation) → **8c native
fixed point: eco-compiler-boot ELF == eco-compiler-boot-2 ELF, byte-equal**.

With cafMemo on end-to-end this proves: (a) the JS backend path is
unaffected (Stages 1–5 JS semantics unchanged); (b) a fully-memoized native
compiler compiles the compiler correctly; (c) codegen is deterministic under
memoization (n2 == n3 byte-exact). Note the known ~/.eco env-blind
package-artifact trap: a FIRST post-change leg can differ via stale package
artifacts; the fixed-point gate is 8c's boot == boot-2 comparison, which is
entirely post-change. The `cafm=1` hash token forces package-artifact
rebuild, which should sidestep the trap entirely.

## 6. Benchmark — Run S in `benchmarks/runtime-calls.md`

Follow the file's Methodology section exactly (cold-cache Stage-7a
self-compile census). This change is an A/B of the **build engine's codegen**
(`ECO_CAF_MEMO`), workload engine = default:

```bash
BK=build/compiler/build-kernel
# Phase 1a — OFF binary:
rm -rf "$BK/eco-stuff"
ECO_CAF_MEMO=0 cmake --build build --target eco-compiler
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-compiler-cafoff"
# Phase 1b — ON binary (default):
rm -rf "$BK/eco-stuff"
cmake --build build --target eco-compiler
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-compiler-cafon"

# Phase 2 — census runs, interleaved ×3 per side, cold eco-stuff per leg:
rm -rf "$BK/eco-stuff"
( cd "$BK" && ulimit -c 0 && \
    ECO_DISPATCH_STATS=1 /usr/bin/time -v -o timing-<leg>.txt \
    ./bin/eco-compiler-caf<state> make --optimize --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/out-<leg>.mlir /work/compiler/src/Terminal/Main.elm 2> census-<leg>.log )
```

Record per the file's conventions: `sat/gen/typed/fast/distinct` (counts are
deterministic — one census read per side suffices; expect sat to DROP:
decoder-graph and table rebuilds carry closure dispatch), wall ×3
interleaved census-on, **majors/minors from every leg** (Run-K discipline),
output sizes (on-side outputs are larger by design — slots + guards; the
off-side must be byte-identical across its own legs). The two sides' outputs
are NOT comparable byte-wise (the feature changes codegen — unlike
dispatch-neutral runs). Add the `### Run S` section + a summary-table row +
update the *Next* paragraph. Census caveat: `ECO_INLINE_ALLOC=0` is only
needed for CLOSURE-census/GC-byte-stats runs, not the dispatch census.

## 7. Rollback / escape

- `ECO_CAF_MEMO=0` at compile time — old codegen, old hash, old caches.
- Full revert: the feature is additive and localized (Config, Builder
  Config, Ops.elm, Functions.elm, EcoToLLVM.cpp, EcoToLLVMGlobals.cpp,
  EcoToLLVMInternal.h, 3 fixtures) — `git checkout` restores baseline.

## 8. invariants.csv additions (append at category tails, after gates pass)

- `CGEN_068;MLIR_Codegen;CafMemoGuard;enforced;` — a func.func tagged
  eco.caf_memo must be an arity-0 thunk with !eco.value result and a
  matching `__eco_caf$<name>` eco.global referenced by no other function;
  EcoToLLVM's serial post-Stage-2 phase wraps it in entry
  load/icmp-ne-0/early-return + store-before-every-return using the
  globalLoad/StoreValueToI64 barrier forms; 0 is reserved as uninitialized;
  slots are per emitted thunk symbol (per SpecId) and never shared across
  specializations (layouts differ). Sources: Functions.elm|EcoToLLVM.cpp|
  EcoToLLVMGlobals.cpp.
- `HEAP_035;Runtime_Heap;CafSlotRooting;enforced;` — CAF slots are JIT
  roots registered by __eco_init_globals before Elm code runs, evacuated
  in place at minor GC and marked at major GC (null/embedded-constant words
  skipped). Only tagged-!eco.value slots may be rooted: raw-scalar slots
  (a future v2) must stay out of the root set and out of
  createGlobalRootInitFunction's internal-i64 walk. Sources:
  EcoToLLVMGlobals.cpp|NurserySpace.cpp|OldGenSpace.cpp.

## 8b. M4 — nullary custom constructors (SHIPPED 2026-07-23, Run T)

`generateNodeInner`'s `MonoEnum` arm stamps too (same `cafMemo` flag, not a
separate gate): qualifies when enabled, the ctor is not a well-known
constant (True/False/Nothing — embedded immediates, trivial bodies), and
`monoTypeHasEffects` is false on the decomposed result type. Emits the
`eco.global` + `eco.caf_memo` attr on `generateEnum`'s func op; the C++
guard needed zero changes. Fixture `test/codegen/caf_memo_enum.mlir`
(construct.custom-size-0 body, alloc-once + tag dispatch across forced
GCs). Results (Run T): −4.5 % census-on wall on top of Run S, minors
760→727 at 9 majors flat, dispatch-neutral, +274 slots, E2E 1634/1634,
byte-exact bootstrap fixed points. Cumulative CAF arc: −8.9 % wall,
majors 10→9, minors 762→727.

## 9. Execution order & checkpoints

1. Fixtures first is NOT practical here (they need the C++ guard to pass),
   so: implement C++ (§2) + fixtures (§3), build `--target test` deps and
   run JUST the new fixtures via the test binary if it supports filtering
   (`TEST_FILTER=codegen`), THEN the Elm side (§1), then the full gate (§4).
2. Any fixture failure: inspect the JIT-side MLIR (`%ecoc -emit=llvm`
   flavor flags per existing fixture RUN lines) before touching the pass.
3. Full E2E (§4) → bootstrap (§5) → benchmark (§6) → invariants.csv (§8) +
   memory update.

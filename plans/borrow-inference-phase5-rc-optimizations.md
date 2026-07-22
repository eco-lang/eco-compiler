# Borrow Inference — Phase 5: RC Optimization Track (B4 + B5)

Status: IMPLEMENTATION-READY (v2, deep-dive pass). Parent design:
`design_docs/globalopt/borrow-inference-design.md` (v2) §14–§17, §19.3;
milestones B4/B5. Series: `plans/borrow-inference-phase{0..6}-*.md`.

**Dependencies:** Phase 3 (precision floor); Phase 0's B0 report is the
scheduling gate (G1: build the runtime path at all, or stop at the
analysis oracle — design §22.1). Phase 4 improves precision but is NOT
a prerequisite (reification works at B3 precision).
**Decision gate G2** sits after U5.4: dynamic counters must reconcile
with the census before any RC-1 work.

**Goal:** turn the analysis into running code: RC ops emitted behind
`reify=rc`, certified by a checker, executed by a GC-coexisting runtime
RC path, then old-gen reclaim + statically-unique free. **The
`rcManaged` v1 scope has no in-place-mutation targets (verified fact 10)
— the payoff is earlier reclaim, not RC-1; U5.6 is downgraded
accordingly.**

## Verified facts this plan is built on

1. **`MonoExpr` has 18 constructors** (`Monomorphized.elm:913-931`),
   ending `MonoUnit` (`:930`) / `MonoAccessorValue Region Name MonoType`
   (`:931`). The two new constructors and `DropKind` are added to this
   type (design §14.1); insert them right before `MonoUnit` so the
   pre-order the analysis uses is unaffected:
   ```elm
   | MonoRcDup Int MonoExpr
   | MonoRcDrop DropKind Name MonoExpr
   ```
   and, alongside the other top-level unions in the file:
   ```elm
   type DropKind = DropDec | DropFree
   ```
   Neither carries a `MonoType` (the wrapped `e`/`body` supplies it —
   see fact 2's `typeOf` arm). They are produced ONLY by the Phase-6
   borrow pass (BORROW_002) and never serialized.

2. **Definitive `MonoExpr`-match sweep — the design's "13 files, 11
   trivial" is a mis-count (see Design discrepancies).** An exhaustive
   (wildcard-free) `case` on `MonoExpr` becomes a compile error the
   moment the two constructors are added; a `case` with a `_ ->`
   fallthrough does not. Grepping every `case`-arm that lists the tail
   trio `MonoTupleCreate → MonoUnit → MonoAccessorValue` (the fingerprint
   of a full enumeration) across `compiler/src` gives **12** files with
   ≥1 exhaustive `MonoExpr` case. Split by what the arm must DO:

   | File | Exhaustive case(s) — anchor | Arm kind |
   |---|---|---|
   | `Monomorphize/MonoInlineSimplify.elm` | ~10 cases (MonoUnit arms `:1231,2083,2656,3033,3725,3924,4284,5103,5197,5348`) | Debug.todo |
   | `GlobalOpt/MonoGlobalOptimize.elm` | 2 (`:838-870`, `:1293-1312`) | Debug.todo |
   | `GlobalOpt/AbiCloning.elm` | 3 (`:347-365`, `:684-702`, `:851-873`) | Debug.todo |
   | `Monomorphize/Specialize.elm` | `renameTailCalls` (`:5525-5568`) | Debug.todo |
   | `Monomorphize/Analysis.elm` | `:254-272` | Debug.todo |
   | `Monomorphize/Closure.elm` | `:127-133` | Debug.todo |
   | `Monomorphize/ResolveAccessorValues.elm` | `:247/278` (+`:567`) | Debug.todo |
   | `MonoSolver/Diff.elm` | `:302-308` | Debug.todo |
   | `Monomorphize/MonoTraverse.elm` | 4 fns: `foldExprAccFirstChildren` `:237`, `traverseExprChildren` `:474`, `mapExprTypes` `:597`, `anyExprType` `:788` | **REAL (recurse)** |
   | `AST/Monomorphized.elm` | `typeOf` (`:1174-1180`) | **REAL (return inner type)** |
   | `Generate/MLIR/Expr.elm` | `generateExpr` (`:348-454`) | **REAL (emission, §U5.1)** |
   | `Generate/MLIR/BytesFusion/Emit.elm` | `:1804-1810` | **see discrepancy** |

   Files that reference `MonoExpr` but do NOT need an arm (verified
   wildcard-terminated or construct-only; the compiler is the backstop
   for any miss): `MonoSolver/Translate.elm` (constructs, never
   case-matches the tail trio), `BytesFusion/Reify.elm` (specific-shape
   `MonoTupleCreate _ [a,b]` + `_ ->`, `:1545`), `ValidateLayout.elm`
   (`:140`+`_` `:156`), `Staging/ProducerInfo.elm` (`:207`+`_` `:219`),
   `Staging/GraphBuilder.elm` (`:323/497`+`_` `:500`),
   `Staging/Rewriter.elm` (`:342`+`_`), `Generate/MLIR/TailRec.elm` (no
   exhaustive `MonoExpr` case).

   The 8 Debug.todo arms carry BORROW_002's enforcement text (`Debug.todo
   "BORROW_002: pre-Phase-6 pass observed an RC op"`); they compile
   because Elm requires exhaustiveness, and are dead because Phase 6 is
   the terminal GlobalOpt phase. The `MonoTraverse` / `Monomorphized`
   arms are exercised on reified output by the reifier and `Check.elm`,
   so they are real (fact 2 → §U5.1).

3. **Dialect ops already exist — no `Ops.td` edit.** `Eco_IncrefOp`
   (`Ops.td:2761`, `ins Eco_Value:$value, I64Attr:$amount`, `outs ()`),
   `Eco_DecrefOp` (`:2777`, `ins Eco_Value:$value`), `Eco_FreeOp`
   (`:2803`), plus `DecrefShallowOp/ResetOp/ResetRefOp`. `RCElimination`
   (`RCElimination.cpp:43-62`) hard-errors on every one in tracing mode
   ("`eco.incref is not supported in tracing GC mode`"). The Stage-3
   body conversion marks the whole `EcoDialect` illegal
   (`EcoToLLVM.cpp:367 addIllegalDialect<EcoDialect>()`), so any RC op
   surviving into Stage 3 (rc-mode) MUST be matched by a lowering
   pattern or `applyFullConversion` fails.

4. **Emission idiom (compiler).** `Ops.mlirOp ctx "opcode"` +
   `opBuilder.withOperands`/`withAttrs`/`withResults`/`isTerminator`/
   `build` (`Ops.elm:99-101`); the zero-result-with-operand template is
   `ecoReturn` (`Ops.elm:525-535`: `withOperands [operand]` +
   `_operand_types` `ArrayAttr [TypeAttr operandType]`, no `withResults`).
   In-scope `Name → (ssaVar, MlirType)` lookup is
   `Ctx.lookupVar ctx name` (used at `Expr.elm:355`). `ExprResult =
   { ops, resultVar, resultType, ctx, isTerminated }` (`Expr.elm:83-96`).

5. **Pipeline gate.** `struct EcoPipelineOptions {}` is empty today
   (`EcoPipeline.h:33`) — add `bool rcMode = false;`. `RCElimination` is
   added at `EcoPipeline.cpp:53` inside `buildEcoToEcoPipeline`. Flag
   template to copy: `static cl::opt<bool> enableOpt("opt", …, cl::init(false))`
   (`ecoc.cpp:144-147`). `EcoPipelineOptions` is constructed by four
   callers: `ecoc.cpp:195`, `EcoNativeDriver.cpp:106`, `EcoRunner.cpp:189`,
   `eco-boot.cpp:378`.

6. **Lowering infra.** `EcoRuntime::getOrCreateFunc(builder, name,
   funcType, bool gcLeaf=false)` (`EcoToLLVMRuntime.cpp:122-154`); with
   `gcLeaf=true` it stamps `passthrough=["gc-leaf-function"]` (`:143-148`).
   Every runtime decl must be pre-declared in `materializeAllRuntimeDecls`
   (`:1152-1212`) before `freeze()`, else the frozen-miss assert fires
   (`:135-137`). Decl template: `getOrCreateStoreField → eco_store_field`
   (`:462-476`, gcLeaf). Body patterns are populated at
   `EcoToLLVM.cpp:407-415` (e.g. `populateEcoHeapPatterns`), declared in
   `EcoToLLVMInternal.h:955-1009`. Pattern-class template:
   `BoxOpLowering` (`EcoToLLVMHeap.cpp:196-272`) — `OpConversionPattern`
   holding `const EcoRuntime &`, `matchAndRewrite` does
   `runtime.getOrCreate…`, builds the call, `rewriter.replaceOp`/`eraseOp`.
   JIT symbols: `buildRuntimeSymbolMap` (`RuntimeSymbols.cpp:28+`, one
   `symbolMap[interner("eco_store_field")] = ExecutorSymbolDef(
   ExecutorAddr::fromPtr(&eco_store_field), Exported)` per export,
   `:242`); `registerRuntimeSymbols` has both `ExecutionEngine` (`:995`)
   and `EcoJIT` (`:1001`) overloads, invoked at `ecoc.cpp:327` (JIT
   `--emit=jit`) and `EcoRunner.cpp:227` (E2E harness) — so one addition
   to `buildRuntimeSymbolMap` covers both JIT-test symbol tables.

7. **Header + rcManaged.** `Header.refcount : 15` bitfield
   (`Heap.hpp:160`, "unused currently"), beside `color:2` (`:155`),
   `age:2` (`:157`). `RC_SATURATED = 0x7FFF` = 2¹⁵−1 fits exactly.
   `rcManaged` compiler predicate (v1): `MString` (`Monomorphized.elm:208`)
   + the `MCustom` for `Bytes.Bytes`. Runtime v1 tag set (pointer-free
   flat buffers): `Tag_ByteBuffer`, `Tag_StringUtf8Leaf`, `Tag_String`
   (inline UTF-16), `Tag_LargeByteHeader`/`Tag_LargeStringHeader` bodies
   (HEAP_026 pinned); the view/slice/rope tags
   (`Tag_StringUtf8View`, `Tag_ByteBufferSlice`, `Tag_StringSlice`,
   `Tag_StringRope`) carry interior backing pointers and are EXCLUDED
   from RC-1 (S3 corollary) though still traced (`StringOps.hpp:42-108`).
   Interning/immortal stamping site: `internLiteral`
   (`RuntimeExports.cpp:515-527`), called by `eco_alloc_string_literal`
   (`:531`) and `eco_alloc_string_literal_utf8` (`:551`); both allocate
   `allocatePermanent(size, Tag_String/…)` in old gen.

8. **U5.5 free APIs.** `inline size_t getObjectSize(void *obj)`
   (`AllocatorCommon.hpp:224`); `OldGenSpace::freeLargeBodyCell(
   LargeBodyMeta& m)` (`OldGenSpace.hpp:973`); `Allocator::isInNursery(
   void *ptr)` / `isInOldGen(void *ptr)` (`Allocator.hpp:191/194`);
   `allocatePermanent(size_t, Tag)` (`:124`); `heapGeneration()` (`:146`).
   `Tag_Free` cell convention: `Header.age & 0b01 == 1` = "on a free
   list" sentinel (`Heap.hpp:124-152`); size-class free lists +
   `freeLargeBodyCell`/HEAP_027 in `OldGenSpace` (`OldGenSpace.hpp:66-106`,
   `GCStats.hpp:427`).

9. **Statistics mechanism.** getenv-gated, init-on-first-use `static bool`
   + relaxed atomics + `std::atexit` stderr dump. Template:
   `ECO_DISPATCH_STATS` (`RuntimeExports.cpp:812-860`:
   `dispatchStatsInit` reads `getenv("ECO_DISPATCH_STATS")`,
   `dispatchStatsEnabled` memoizes, `dispatchStatsRecord` is
   allocation-free; dump `fprintf(stderr, "[dispatch-stats] …")`). Copy
   verbatim for `ECO_RC_STATS`.

10. **HONESTY CHECK — the RC-1 candidate set is empty (verified).**
    Every entry point in `elm-kernel-cpp/src/core/String.cpp`
    (`length, append, join, cons, uncons, fromList, map, filter, foldl,
    foldr, slice, split, lines, words, reverse, toUpper, toLower, trim,
    trimLeft, trimRight, startsWith, endsWith, contains, indexes, toInt,
    toFloat, fromNumber`) either reads only or **delegates to
    `StringOps::*`, which allocate a fresh result** (`fromList`:56-115 is
    two-pass count-then-fresh-alloc-then-fill; `map/filter/reverse/
    toUpper/…` return new strings — Elm strings are immutable
    rope/leaf/slice). `Bytes.Encode.encode` (`elm-kernel-cpp/src/bytes/Bytes.cpp:301`) →
    `BytesOps::concat`, which sizes and fills a **freshly allocated**
    `Tag_ByteBuffer` (already optimal; no owned buffer to reuse).
    `Bytes.Decode` reads only. **There is no owned-taking, in-place
    mutating primitive on any pointer-free buffer type.** RC-1
    (count==1 ⇒ mutate-in-place-else-COW) therefore has zero v1 targets
    (§U5.6 downgrade; matches design §22.1's own hedge and §17 C1).

### Design discrepancies

- **§14.1 / §15.1 "13 files … 11 trivially (`Debug.todo`) … MLIR
  Expr.elm/Ops.elm non-trivially".** Re-count (fact 2): **12** files
  hold exhaustive `MonoExpr` cases, and only **8** get `Debug.todo`.
  `MonoTraverse.elm` (4 traversal fns) and `Monomorphized.typeOf` are
  shared utilities the reifier and `Check.elm` run over reified output —
  their arms must be REAL (recurse / return the wrapped type), not
  `Debug.todo`, or Phase 6 and the checker crash on their own output.
  `Ops.elm` has NO `MonoExpr` case at all; it gains new emission-builder
  *functions* (`ecoIncref/ecoDecref/ecoFree`), not an arm. Recorded in
  open_questions.
- **BytesFusion (`Emit.elm:1804`, `Reify.elm:1545`) matches exactly the
  rcManaged types at emission time.** A `MonoRcDup`/`MonoRcDrop`
  wrapping a `Bytes.Encode`/`Decode` argument would sit between the
  fusion matcher and the codec chain and silently defeat fusion (a
  perf, not correctness, regression). v1 resolution: `Emit.elm`'s
  exhaustive arm is REAL and transparent — recurse through `MonoRcDup
  n e`/`MonoRcDrop _ _ body` to the wrapped expression when probing for
  the fusion shape, and re-emit the RC op around the fused result;
  `Reify.elm` needs no arm (wildcard). Flagged in open_questions —
  the cleaner long-term fix is for the reifier to place codec-argument
  dups/drops OUTSIDE the fusible sub-tree.
- **§17 / §18 B5 call U5.6 "the payoff unit" ("RC-1 checks in the scoped
  buffer kernels (Bytes ops first)").** Fact 10 shows the candidate set
  is empty: the v1 pointer-free kernels are purely functional. **U5.6 is
  rewritten to record this and defer RC-1 to v2 (arrays), where
  pointer-carrying containers with `map`/`update` reuse are the real
  Perceus payoff but are S6/RC_004-excluded from v1.** The genuine v1
  win is U5.5 (earlier reclaim of dead buffers). Recorded in
  open_questions as a milestone-scoping correction.

## U5.1 — Reification core + the 12-file sweep (compiler-side)

Files: **edit** `AST/Monomorphized.elm` (fact 1: add `MonoRcDup`/
`MonoRcDrop`/`DropKind`; add the `typeOf` arm `:1174` region returning
`typeOf e`/`typeOf body`); the 11 other sweep files (fact 2 table);
`Generate/MLIR/{Expr,Ops}.elm` (emission); and the Phase-6 borrow pass
that PRODUCES the ops (**create** `GlobalOpt/Borrow/Reify.elm`, wired
into `MonoGlobalOptimize.globalOptimizeWithStats` after
`annotateCallStaging`, `MonoGlobalOptimize.elm:150`, when the config
`borrow.reify = rc`). Reconfigure (`cmake --preset build`) after
creating `Reify.elm`.

**Sweep arms (fact 2):**
- 8 Debug.todo files: two arms each,
  `MonoRcDup _ _ -> Debug.todo "BORROW_002: pre-Phase-6 pass observed an
  RC op"` and the same for `MonoRcDrop _ _ _`.
- `MonoTraverse.elm` (real): in `foldExprAccFirstChildren`
  `MonoRcDup _ e -> f acc e` / `MonoRcDrop _ _ body -> f acc body`; in
  `traverseExprChildren` recurse the child and rebuild
  (`MonoRcDup n e -> let (e1,c1)=f ctx e in (MonoRcDup n e1, c1)`;
  `MonoRcDrop k x body -> let (b1,c1)=f ctx body in (MonoRcDrop k x b1,
  c1)`); `mapExprTypes` recurse into the child only (no type field on
  the RC ops); `anyExprType` recurse into the child.
- `Monomorphized.typeOf`: `MonoRcDup _ e -> typeOf e`;
  `MonoRcDrop _ _ body -> typeOf body`.
- `Expr.generateExpr` and `BytesFusion/Emit.elm`: below / discrepancy.

**Placement (produced by `Reify.elm`)** per design §14.2 (all four
review-hardened rules), from Stage-D `Occ` records + solved modes + ltP:
move at `onBoundary ltP path` (emit nothing); dup at owned non-final,
batched at the FIRST coalesced occurrence with "nothing intervening at
all"; **coercion dups** (§9.5) at every borrowed-producer→owned-position
point; drops at scope end with **mandatory hoisting before any
`MonoTailCall`** (BORROW_005); compensating drops in asymmetric if/case
arms; `immortal` resources skipped.

**MLIR emission (`Expr.generateExpr`, real arms):**
- Add to `Ops.elm` (fact 4 template), three zero-result builders:
  ```elm
  ecoIncref : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
  ecoDecref : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
  ecoFree   : Ctx.Context -> String -> ( Ctx.Context, MlirOp )
  ```
  each `mlirOp ctx "eco.incref|decref|free" |> withOperands [v] |>
  withAttrs …`, no `withResults`, not a terminator. `ecoIncref` adds
  `amount` (I64Attr matching `Ops.td:2772`); all three add
  `_operand_types = ArrayAttr [TypeAttr Types.ecoValue]` (as `ecoReturn`
  does — the op takes `Eco_Value:$value`).
- Arm `Mono.MonoRcDup n e`: `let r = generateExpr ctx e; (c1, op) =
  Ops.ecoIncref r.ctx r.resultVar n in { r | ops = r.ops ++ [op],
  ctx = c1 }` — the dup yields the same value/type as `e`.
- Arm `Mono.MonoRcDrop k x body`: `let r = generateExpr ctx body;
  (xVar, _) = Ctx.lookupVar r.ctx x` (BORROW_004 in-scope lookup lands
  here) `; (c1, op) = (case k of DropDec -> Ops.ecoDecref; DropFree ->
  Ops.ecoFree) r.ctx xVar in { r | ops = r.ops ++ [op], ctx = c1 }` —
  the drop is emitted AFTER `body`'s ops, result stays `body`'s.
  Precondition `not r.isTerminated` (guaranteed by BORROW_005 hoisting;
  the checker U5.2 re-verifies).
- `BytesFusion/Emit.elm` arm: transparent recurse (see discrepancy).

## U5.2 — `Borrow/Check.elm` certifying checker (lands WITH U5.1)

**Create** `compiler/src/Compiler/GlobalOpt/Borrow/Check.elm`
(reconfigure). Per design §19.3, under config `borrow.validate`, ONE
linear walk per def over the reified output + the recorded Phase-6 facts
(`Occ` paths, solved modes, ltP), returning `Result (List String) ()`:
linearity (every owned resource moved exactly once or dropped on every
path; no use-after-move via `Lifetime.endsBefore` recheck against the
`Occ` paths); coercion completeness (every owned-demanding position fed
by a move / dup / owned-fresh producer, never a bare Borrowed source,
§9.5); BORROW_004 (every `MonoRcDrop` names an in-scope binding —
mirror `Ctx.lookupVar`'s scope discipline over a `Set Name`); BORROW_005
(no `MonoRcDrop` after a `MonoTailCall` in the same body); BORROW_003
(no RC op targets an `immortal` or non-`rcManaged` resource under
`reify=rc`). Uses `MonoTraverse.foldExprAccFirst` — which is exactly why
its RC arms are real (fact 2). Runs over the full corpus at the U5.4
gate. No pipeline byte-effect when `borrow.validate=off`.

## U5.3 — Runtime RC path

- **`bool rcMode` in `EcoPipelineOptions`** (`EcoPipeline.h:33`, default
  false). In `buildEcoToEcoPipeline` gate line 53:
  ```cpp
  if (!opts.rcMode)
      pm.addPass(eco::createRCEliminationPass());   // tracing: RC ops are a bug
  ```
  rc-mode leaves the ops for Stage 3. `--rc-mode` cl::opt in `ecoc.cpp`
  (copy `enableOpt`, `:144`); set `pipeOpts.rcMode = rcMode;` before
  `buildEcoToLLVMPipeline` (`:195`). The three in-process drivers
  (`EcoNativeDriver.cpp:106`, `EcoRunner.cpp:189`, `eco-boot.cpp:378`)
  don't parse the ecoc CLI — set `pipeOpts.rcMode = (getenv("ECO_RC_MODE")
  != nullptr)` there. **The compiler-side `borrow.reify=rc` config
  drives when RC ops are EMITTED; the ecoc/env flag must be set on the
  same builds — who wires it in the production build harness is an open
  question (see open_questions).** Native self-compile lowers via
  `EcoNativeDriver` (per memory: solver binaries mint through the native
  binary, not the 4 GB node Stage-5), so the env path is load-bearing.
- **Lowering `Passes/EcoToLLVMRc.cpp` (new).** Three
  `OpConversionPattern` classes on the `BoxOpLowering` template
  (`EcoToLLVMHeap.cpp:196-272`), each holding `const EcoRuntime &`:
  `IncrefOpLowering` (`ptrtoint value → i64`, i64 const `amount` from
  the attr, `call eco_rc_incref(word, amount)`, `rewriter.eraseOp`),
  `DecrefOpLowering` (`call eco_rc_decref(word)`), `FreeOpLowering`
  (`call eco_rc_free(word)`). Add `void populateEcoRcPatterns(
  EcoTypeConverter&, RewritePatternSet&, const EcoRuntime&)` to
  `EcoToLLVMInternal.h` (beside `:955`) and call it in the body block at
  `EcoToLLVM.cpp:415` (after `populateEcoErrorDebugPatterns`). Add
  `EcoToLLVMRc.cpp` to `runtime/src/codegen/CMakeLists.txt`.
- **Runtime decls (`EcoToLLVMRuntime.cpp`).** Add
  `getOrCreateRcIncref/RcDecref/RcFree` (each `getOrCreateFunc(b, name,
  funcTy, /*gcLeaf=*/true)` — the helpers never allocate, no safepoint,
  so RS4GC inserts no statepoint and the i64 word crosses legally) and
  append them to `materializeAllRuntimeDecls` (`:1152-1212`). Signatures:
  `eco_rc_incref(i64,i64)→void`, `eco_rc_decref(i64)→void`,
  `eco_rc_free(i64)→void`.
- **Helpers `allocator/RefCount.cpp` (new)** — design §16.2 verbatim
  (`hpFromBits(word)` NOT `HPointer{word}` first-field trap; `word==0 ||
  hp.ptr_ind` early-returns — RC_003/REP_CONSTANT_002, never range
  checks; `Header*` cast since HEAP_028 word IS the address;
  `RC_SATURATED=0x7FFF` sticky; `rc==0` untracked no-op; decref-to-0 →
  `eco_rc_reclaim(h)`, a stub `return;` until U5.5). Declare the three
  `extern "C"` in `allocator/RuntimeExports.h`; register in
  `RuntimeSymbols.cpp buildRuntimeSymbolMap` (fact 6 — one block each,
  `ExecutorAddr::fromPtr(&eco_rc_incref)` etc.) so both JIT paths
  (`ecoc.cpp:327`, `EcoRunner.cpp:227`) resolve them. **There is no
  single "allocator CMake target": the allocator `.cpp` sources are
  enumerated in explicit (non-glob) source lists in several
  `CMakeLists.txt`.** Add `RefCount.cpp` alongside `RuntimeExports.cpp`
  in EVERY list that produces a binary reaching rc-mode/lowered code (the
  RuntimeSymbols.cpp JIT symbol-map only feeds the JIT path — the native/
  AOT/E2E link lines need the object file itself, or they fail to link
  with undefined `eco_rc_incref`/`decref`/`free`): the three codegen
  targets in `runtime/src/codegen/CMakeLists.txt` (where
  `RuntimeExports.cpp`+`Allocator.cpp` appear at `:448-449`, `:567-568`,
  `:647-648`) and `eco-kernel-cpp/CMakeLists.txt:172`. The top-level
  `ecor` GC-debug target (`CMakeLists.txt:385-394`) lists the allocator
  sources but not `RuntimeExports.cpp`; add `RefCount.cpp` there too only
  if `ecor` links lowered rc code. (`test/CMakeLists.txt:79` explicitly
  excludes the allocator sources, so no change there.)
- **Alloc-site count init.** Set `header.refcount = 1` at the sites that
  mint rcManaged tags: the string/bytes allocators in
  `RuntimeExports.cpp`/`StringOps.cpp`/`ElmBytesRuntime.h` (one line each,
  beside the existing `header.size`/`tag` writes — the field is
  zero-init today, fact 7). At `internLiteral` (`RuntimeExports.cpp:515`)
  and the two `eco_alloc_string_literal*` lambdas (`:531/551`), stamp
  `header.refcount = RC_SATURATED` (immortal, RC_002/S5). **Header-
  preservation obligation (§16.2):** minor-GC copy + promotion must
  carry the header word (incl. `refcount`) verbatim; audited + pinned by
  an ECO_HEAP_VALIDATE assertion at U5.4.
- **`ECO_RC_STATS`** (fact 9 template): `dup`/`drop`/`free` atomic
  counters bumped inside the three helpers, `[rc-stats] dup=… drop=…
  free=… reclaimed=…` atexit line.

## U5.4 — B4 gate run (decision gate G2)

- Full E2E green flag-on (`reify=rc` + `ECO_RC_MODE=1`/`--rc-mode`):
  `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
  (run ONCE; grep the file). Touch all test `.elm` first (harness
  env-blindness trap, §19.4). Run serially vs `elm-tests`
  (typed-artifacts cache race).
- **Census ↔ `ECO_RC_STATS` reconciliation**: the B2/B3 static would-be
  dup/drop/free counts vs the dynamic executed counts must line up (the
  placement-bug detector, §19.2). `grep -a "[rc-stats]"` + the census
  line (`ECO_BORROW_REPORT=1`).
- ECO_HEAP_VALIDATE clean, **including the refcount-survives-copy/
  promotion assertion** (§16.2).
- Tracing mode (`reify=off`) byte-identical flag-off (RCElimination still
  hard-errors on any leaked RC op).
- Checker (U5.2) green over the full corpus under `borrow.validate`.
- **All-owned isolation** (§19.2): set the `allOwnedFlag : Bool` — the
  second argument to `Borrow/Solve.solve` (defined by the Phase-2 plan,
  `borrow-inference-phase2-intradef-analysis.md:414` signature; its Stage
  C seeds **every** access `Owned` when True — the §19.2 soundness-
  isolation switch that forces every `reifiedMode = Owned`) — to
  reproduce the fully-pessimistic Perceus placement. Any bug
  reproducing here is in reification/runtime, not the analysis.
  (Cross-phase dependency: Phase 3 is a prerequisite; the flag itself is
  a Phase-2 solver knob.)
- Wall/footprint measured (RC ops cost before payoff — expect a small
  regression; payoff is U5.5). Record majors with walls (major-GC
  trigger-lottery lesson).

## U5.5 — Old-gen reclaim + `DropFree` (B5a — the v1 payoff)

- **`eco_rc_reclaim(Header* h)`** in `RefCount.cpp` per §16.3, dispatch
  on residency (fact 8): **nursery** (`Allocator::isInNursery`) → no-op
  (the copying collector reclaims it free at the next minor GC; the zero
  count already paid for itself as a static `DropFree`/uniqueness fact);
  **old gen** (`isInOldGen`) → convert to `Tag_Free` with
  `header.size = getObjectSize(h)`, set the on-free-list sentinel
  (`age & 0b01`), link into the size-class free list — generalize
  `freeLargeBodyCell`/HEAP_027 to mutator time; **pinned large bodies**
  (HEAP_026) via `OldGenSpace::large_bodies_`. v1 is pointer-free only:
  no child traversal, `decref_shallow` vs `decref` moot. Respect
  HEAP_021/023/027 (no coalescing across block boundaries mid-mutator;
  keep the sentinel discipline the sweep expects).
- **`DropFree` on**: the analysis already proves the class (§17 H3);
  the checker gains the BORROW_003 static-unique condition; `Reify.elm`
  emits `MonoRcDrop DropFree` → `eco.free` where zero dups reach the
  class on any path.
- Gate: E2E + string/slice suite (`TEST_FILTER=…`) + ECO_HEAP_VALIDATE;
  **footprint watch** (peak/live) — this is where the reclaim win shows.

## U5.6 — RC-1 in-place mutation — NO v1 targets (downgraded)

**This unit does not ship in v1.** Fact 10: the pointer-free buffer
kernels (`String.cpp` / `Bytes.cpp` / `StringOps`) are purely functional
— every transform allocates a fresh result, and `Bytes.Encode` already
fills a fresh buffer. There is no owned-taking, in-place mutating
primitive for an RC-1 `count==1 ⇒ mutate-else-COW` check to guard, so
the candidate set is empty. RC-1 belongs to v2 arrays (pointer-carrying
containers with `map`/`update`/`set` reuse — the real Perceus payoff),
which are S6/RC_004-excluded from v1 (a promoted array storing a nursery
pointer creates a GC-invisible edge; v2 resolves via builder-style
nursery pinning or a scoped remembered set). Kept as a numbered unit to
preserve the series' IDs and to record the S1–S6 conditions (§17) that
the v2 arrays plan must satisfy; the `updateCopiedHeapFields` census
counter (§13) and per-field dup selectors (§22.4) are its hard
prerequisites. **No code, no gate here** — the B5 payoff is U5.5.

## U5.7 — Benchmark verdict

Per `benchmarks/runtime-calls.md` methodology: interleaved ×3, cold
Stage-7a, majors recorded with walls; census-comparable legs with the
settled env set. Report wall + **peak/live footprint** (the U5.5 win)
+ reclaim counts (`ECO_RC_STATS reclaimed=`). Micro-shapes: the paper's
text_stats / parser-combinator inputs, plus a Bytes-heavy encode/decode
loop (the class U5.5 actually reclaims). Self-compile + elm-aws-codegen
canaries. Go/no-go recorded here + in `benchmarks/`: `reify=rc` default
posture (given no RC-1, the bar is "reclaim + DropFree beat their RC-op
overhead").

## Gates summary

U5.4 = G2 (census↔`ECO_RC_STATS` reconciliation + heap-validate +
tracing byte-identity + checker green) · U5.5 E2E + string/slice +
heap-validate + footprint · U5.6 no-op (v2) · U5.7 verdict published in
`benchmarks/` + this plan's as-built. Every full-E2E leg: run ONCE, grep
`/tmp/test_output.txt`; touch test `.elm` before flag-on; serial vs
`elm-tests`. Reconfigure (`cmake --preset build`) after adding
`Reify.elm`/`Check.elm`; add `EcoToLLVMRc.cpp` to
`runtime/src/codegen/CMakeLists.txt`, and `RefCount.cpp` to every
allocator source list that reaches lowered code (U5.3: the three codegen
targets + `eco-kernel-cpp/CMakeLists.txt`, NOT `test/CMakeLists.txt`).

## References

Design §14 (reification incl. all four review-hardened placement rules),
§15 (backend/rcMode/emission), §16 (runtime helpers/reclaim), §17 (RC-1
S1–S6/H1–H4/C1 — recorded for v2), §19.2/19.3 (all-owned isolation;
checker), §20 (BORROW_002-005, RC_001-004), §21 (budgets), §22.1 (the
stop-at-oracle question this plan's fact 10 sharpens). Code anchors:
`Monomorphized.elm:913-931,1174` · the fact-2 sweep table ·
`Expr.elm:83-96,348-454`, `Ops.elm:99-101,525-535` · `Ops.td:2761-2814`,
`RCElimination.cpp:43-62`, `EcoPipeline.{h:33,cpp:53}`, `ecoc.cpp:144-195`
· `EcoToLLVM.cpp:367,407-415`, `EcoToLLVMHeap.cpp:196-272`,
`EcoToLLVMRuntime.cpp:122-154,462-476,1152-1212`, `EcoToLLVMInternal.h:955` ·
`RuntimeSymbols.cpp:28-252,995-1001` · `Heap.hpp:124-160`,
`AllocatorCommon.hpp:224`, `OldGenSpace.hpp:66-106,973`,
`Allocator.hpp:124-194`, `RuntimeExports.cpp:454-563,812-860` ·
`String.cpp` / `elm-kernel-cpp/src/bytes/Bytes.cpp:301` /
`BytesExports.cpp:144` (fact 10).

# Precomputing the whole-program LLVM steps before an MLIR-level split

**Status:** research note, 2026-10-02. Nothing is built.

**Context:**
- Loop doc: `benchmarks/backend-opt-loop.md`, entries TL and DV1.
- Plan: `plans/backend-lowering-optimization.md`.

## 0. The goal

Today `eco-boot-native` does the following:
1. Translate the whole MLIR module into ONE `llvm::Module`.
2. Run serial whole-program LLVM steps.
3. Externalize, serialize to bitcode, and lazily re-parse it into 24 per-partition `LLVMContext`s.

Steps 1–3 are about 20 s of single-core time, out of a 44 s lowering.

The proposed redesign:
- Split the program into partitions **in MLIR**. The MLIRContext is thread-safe.
- Translate each partition in parallel into its own `LLVMContext`.
- Do all LLVM work per partition.

This removes the serial translation (6.7 s) and the serialize/re-parse round trip (3.7 s plus the
per-worker parse). The serial LLVM passes either become per-partition work or move up into MLIR.

The blocker is four whole-program LLVM steps. The question here is whether, for each one, the
whole-program part can be computed on the MLIR side or in the Elm front-end, and handed to
per-partition LLVM work as precomputed facts.

## 1. Verdicts

| Step | Today (serial) | Verdict | Where the global part goes |
|---|---|---|---|
| Internalize + GlobalDCE reachability | 0.4 s, plus 0.5 s prologue DCE | **Fully movable** | MLIR pass after `EcoTailConversions` |
| Capacity-hoisting budgets (CGEN_074) | 0.95 s, plus 0.63 s `$cap` prepass | **Movable, identical results**; rewriting stays per partition | MLIR plan pass, results as function attributes |
| gc-free leaf propagation (CGEN_072) | 0.29 s | **Movable with conditions**: a marker "may-GC" table, a per-partition check, and it must run after the cap plan | MLIR pass, results as `gc-leaf-function` passthrough |
| IPSCCP prologue | 5.7 s | **Probably movable to the Elm front-end.** Its value is unmeasured; measure first | Front-end constant thunks + constant arguments |

## 2. Internalize + GlobalDCE reachability

**What it does.**
- `internalizeAndDCEForExecutable` (`EcoBackend.cpp:1287-1307`), exe output only.
- Internalizes every definition except `eco_main` and `__eco_init_globals`. Those are the only
  names `eco_entry.cpp` resolves.
- Runs GlobalDCE, which also removes dead declarations.

**No reachability edge to a generated definition appears after translation.** Marker expansions
only add references to runtime-provided symbols. Everything else is already an MLIR symbol use:
eval descriptors and their sat slots (`addressof` in global initializers), `_fast_evaluator`, CAF
guards, string-literal slots, type tables and ports.

The one removal after translation is the `$cap` AlwaysInliner deleting dead internal bodies. So
MLIR reachability is a sound superset of what LLVM removes.

**Design.** One module pass, after `EcoTailConversions` (`EcoListCursor` adds marker callees, so
it must come after that):
1. Collect each top-level op's edges in parallel. This reuses B3b's collector: `getSymbolUses`
   plus an attribute-dictionary walk.
2. Run a serial BFS from `main` and `__eco_init_globals`, over about 100k nodes, in tens of ms.
3. Erase the unreached symbols in module order.

It replaces the EcoToLLVM unused-decl strip, because unreached is a superset of unused. Estimated
cost is under 1 s, run in parallel.

**Optional:** compute reachability before `createGlobalRootInitFunction`, so dead `eco.global`
slots and their root registrations also disappear. Today's GlobalDCE structurally cannot do that.

**What linkage must still provide.** Internal linkage is LLVM's closed-world signal. It is
needed by IPSCCP, by CGEN_074's eligibility rule (`hasLocalLinkage`) and by the `$cap` inliner's
dead-body deletion. After the split, the MLIR pass should record each symbol's referring
partitions:
- A symbol referenced only by its owner partition gets **internal** linkage in that partition.
- A cross-partition symbol gets external + hidden.

That is better than today's workers, where everything is external. Cap-hoist eligibility should
use an explicit MLIR fact ("no addressof, all callers known") instead of linkage.

**Risks.**
- A missed reference form gives an undefined symbol at link time, so it fails loudly.
- Keep the pass exe-only (not `.o`, `.so` or JIT), so `test/codegen` CHECK-NOT fixtures are
  unchanged.
- **Measure first:** how much today's GlobalDCE still removes after the front-end `pruneDead`
  (one define count before and after).

## 3. Capacity-hoisting budgets (and the `$cap` machinery)

**What it does** (`EcoBackend.cpp:2875+`):
- **Phase A (per function):** `ownBytes` from `__eco_alloc_inline(size)` markers outside CFG
  cycles; the ⊤ reasons; eligibility (not interposable, not address-taken, local).
- **Phase B (interprocedural):** a budget fixpoint over call-graph SCCs, in Tarjan order, capped
  at K ≤ 4096. The fixpoint is unique, so budgets do not depend on visit order.
- **Phase C:** the set of covered functions.
- **Phase D/D2 (local):** run scans, ensure diamonds and the §2.6 asserts.
- **`expandInlineAllocs`** then skips the checks for covered and unchecked markers.

`$cap` variants are created by the **Elm front-end** (`Lambdas.elm:327`). The backend only
force-inlines bodies of 64 or fewer instructions (`runCapInlinePrepass`).

**Every Phase A input is visible in the llvm dialect at the end of the MLIR pipeline:**
- markers with constant sizes come from `emitInlineAllocWithHeader`;
- gc-leaf facts are `passthrough` attributes;
- marker expansions only add acyclic diamonds, so CFG cycles are unchanged.

To get identical results, three things must be emulated:
- the entry-rooted SCC walk, which skips unreachable blocks;
- the direct-call rule: `addressof` + call with a matching type counts as direct;
- "local after internalization". This comes from §2's pass.

**Design:**
1. Add an MLIR pass `EcoCapHoistPlan`, last before the split. Phase A runs per function in
   parallel; Phase B is the same Tarjan, about free at 98k nodes.
2. Attach `passthrough` string attributes:
   - `"eco-cap-covered"`;
   - `"eco-cap-budget"="N"` on every non-⊤ function, **including N = 0**. §2.6(b) needs
     "budget 0 and not ⊤".
3. The split copies them onto cross-partition declarations.
4. Per partition, `applyCapacityHoisting` runs in a "plan-given" mode: it skips A–C and reads
   callee attributes. D/D2 and the §2.6 asserts are unchanged; §2.6(a) becomes a per-partition
   check.
5. Eligibility must never be recomputed per partition. Externalization would make it wrong.

**`$cap` inlining across partitions.** Copy each `$cap` body that a partition calls directly
into that partition as `available_externally`. The owner keeps the address-taken definition. The
per-partition prepass then applies the same 64-instruction test to an identical body, so its
decisions match today's. Instruction counts are only known after expansion, so copy every
directly called `$cap`, or apply a loose MLIR op-count cap.

Rejected alternatives:
- Co-location distorts LPT balance.
- MLIR-side inlining changes the order of runs and needs a new REP_LLVM_002 argument.

**Cost and fidelity.**
- Identical with the emulations above; sound but weaker if gaps are handled conservatively.
- The serial remainder is about 0.2 s; Phase A becomes parallel.
- About 300 lines of MLIR pass, plus a plan-given mode and attribute copying.
- Invariant text to amend: CGEN_074, HEAP_034 and CGEN_072 placement.

## 4. gc-free leaf propagation

**What it does** (`propagateGcFreeLeafAttrs`, `EcoBackend.cpp:2740`):
- An optimistic poison worklist over the whole call graph.
- **Seeds:** indirect calls, non-leaf declarations, landing pads and interposable bodies.
- Poison flows from callee to caller.
- Survivors get the `gc-leaf-function` attribute, so RS4GC skips statepoints at their call sites.
- A post-RS4GC assert fails the build if a stamped function contains a statepoint.

Scale: 8,473 of about 87k functions, and about 33.7k call sites de-statepointed with hoisting
on. Worth −1.74 % wall when it shipped.

**MLIR's `EcoMarkGCLeafCalls` is not a partial version of this.** It forwards only the kernel
stubs' `eco.gc_leaf`, one hop.

**Movable to MLIR (llvm dialect, last pass), with four conditions:**
1. **Critical: a marker "may-GC when expanded" table.** Several markers are *declared* gc-leaf in
   MLIR but expand into calls that can GC:
   - `__eco_alloc_inline` (slow path; exempt only when the cap plan marks the marker unchecked);
   - `__eco_list_tail_inline` (expands to a call to `eco_list_tail_hybrid`, which is not a leaf);
   - `__eco_value_eq` arm 3, unless `ECO_VALUE_EQ_GCLEAF=1`;
   - `__eco_sat_begin`/`_end`.

   Trusting their attributes would stamp functions that allocate: missing statepoints, so heap
   corruption. The table belongs in one header shared by the declaration site and the expansion
   site. The expansion should assert it only emits what the table allows.
2. **Backend-only leaf stamps** must move onto the MLIR declarations: scratch helpers,
   `eco_bump_state`, `eco_follow_forward`, `__eco_resolve_fwd`, the slot barriers. If they are
   missed, the result is only less precise.
3. **The direct-call rule mirrors `getCalledFunction`.** `llvm.intr.*` ops count as leaf; libcalls
   without a leaf attribute count as poison.
4. **Order: after the cap plan.** Otherwise the result is stale-conservative and loses about
   6.1k stamped functions and about 22.6k de-statepointed sites.

**Per-partition safety net, the key point.** After marker expansion, each partition checks that
every stamped definition calls only leaf callees, where cross-partition stamped declarations
count as leaf. By induction over the partitions this proves the global property, and it also
catches musttail calls, which RS4GC leaves unstatepointed. Keep the existing post-RS4GC assert
too.

Together they turn any disagreement between MLIR and LLVM into a **build failure**, never heap
corruption. The split must copy the passthrough attribute onto declarations. The worklist is
order-independent, so the result is deterministic.

## 5. The IPSCCP prologue

> **MEASURED 2026-10-02** (`benchmarks/backend-opt-loop.md`, entry "IPO").
> - Without the prologue the self-compile is **+1.8 %** slower (110.33 s against 108.40 s, N = 3
>   each, ranges do not overlap).
> - **All of it** is the return values of two hot thunks: `hashBase` (literal 2^26, which turns
>   `mixHash`'s two `srem`s into power-of-two remainders) and `shiftStep`/`branchFactor`
>   (`ceiling (logBase 2 32)` with a `log` call on every `Array.get`).
> - IPSCCP's 2,669 constant arguments, 1,615 dead blocks and wrap flags show no runtime effect.
> - So A1 (phase 1 + phase 2) is the whole replacement. A2 is not needed. The analysis below is
>   kept as written.


**Where its value likely lies.** It is unmeasured, so this is a hypothesis. IPSCCP only tracks
local, never-address-taken functions, which the prologue gets from internalize.

- **Return values of arity-0 thunks (most likely the bulk).** Every reference to a top-level
  constant lowers to `eco.call @thunk()` (`Expr.elm:684-765`). The front-end inliner never
  inlines `MonoVarGlobal`. CAF memoization skips Int, Float and Char.

  So `Array.shiftStep = ceiling (logBase 2 32)` and `bitMask` are recomputed, `llvm.log` and
  all, at every call. IPSCCP folds them to constants. After the split, only about 1 in 24
  callers shares the thunk's partition.
- **Arguments that are the same constant at every call site:** flags, enums, configuration
  values, and self-recursive pass-through arguments.
- **Partition-level IPSCCP does nothing** (16.2 s Σ), for two reasons:
  - every function in a partition is externalized;
  - RS4GC runs before opt in the workers, so every non-leaf callee is an operand of
    `gc.statepoint`, which counts as address-taken.

**Measure first** (not yet run):
1. `eco-boot-native --parallel-opt=none --dump-pre-rs4gc-ir=pre.ll`.
2. `opt -passes='ipsccp<no-func-spec>' -stats` (STATISTICs are live in the assertions build).
3. A script that buckets the changed call sites by thunk vs argument, and by caller count.
4. Confirm the 2.2 % with N ≥ 3 runs, under both dev and cgu.

**Design, in order:**

- **A1, front-end constant thunks.** A `constThunkBySpec` map, like `constCtorBySpec`, and emit
  the constant in `generateVarGlobal`. The thunk funcs stay in place.
  - **Phase 1:** bare literal bodies. No semantic risk.
  - **Phase 2:** a small fixpoint evaluator over closed bodies. It allows only ops with exact
    semantics: 64-bit Int arithmetic, `toFloat`, `logBase`, `ceiling`, `floor`, `Bitwise.*`.
    Each is pinned by a test, because the evaluator must match runtime results bit for bit.
  - Cost is O(#thunks), well under 1 s. Likely most of the 2 %.
- **A2, front-end constant arguments over the Mono graph.** After `MonoInlineSimplify` and
  AbiCloning:
  - Take the meet per (spec, parameter) over direct call sites. Any value use of the spec, and
    any root, forces ⊤.
  - Let-bind the constant at the callee's entry, and iterate with A1.
  - Costs about 1–2 s of Elm time.
  - Codegen-time callers (`$cap`, sret, typed wrappers) must be invisible to A2 or forced to ⊤.
- **Fallback: a custom parallel MLIR "constant-argument summary" pass** (about 0.5 s). Upstream
  `-sccp` is unsuitable:
  - `eco.call` has no `CallOpInterface`;
  - visibility comes too late;
  - LLVM ops have few folders;
  - the solver is serial.
- **Complement: small-callee import.** Workers copy tiny gc-leaf callees in as
  `available_externally`, so the cgu inliner and InstCombine fold them. That covers thunk
  constants without an evaluator, and it adds cross-partition leaf inlining, which IPSCCP never
  provided. It does nothing for argument constants or under dev.

## 6. Dependencies and order

```
front-end A1/A2 (constants)                       ── replaces the IPSCCP prologue
MLIR pipeline ... EcoTailConversions
  → reachability pass (§2): DCE + "referenced only by" data
  → EcoCapHoistPlan (§3): budgets and coverage as attributes   (needs §2's local/address-taken view)
  → gc-free propagation (§4): gc-leaf passthrough             (needs §3; needs the marker table)
  → MLIR split: partition ownership, internal vs hidden linkage, attributes copied onto declarations,
    `$cap` bodies copied in as available_externally
per partition, in parallel: translate → marker expansion → plan-given hoisting → expandInlineAllocs
  → `$cap` prepass → local gc-leaf check → RS4GC (+ assert) → opt → emit
```

## 7. Recommended staging

Each stage is useful on its own, and each fits a single loop step against today's pipeline.

1. **Measurements:**
   - GlobalDCE residual count;
   - IPSCCP `-stats` and an IR diff;
   - a 3-run confirmation of the IPSCCP 2 %.
2. **Front-end A1 phase 1, then phase 2.** These help today's pipeline too: fewer calls in hot
   paths, and less IR for IPSCCP.
3. **The shared marker may-GC table, and the per-partition gc-leaf check.** Pure safety work;
   useful now.
4. **The MLIR reachability pass** (§2). It replaces the decl strip and the LLVM internalize/DCE,
   at the same output.
5. **`EcoCapHoistPlan` + gc-free propagation in MLIR**, checked against the LLVM path in a
   validate mode (byte-identical executable gate).
6. **The MLIR split itself:** partitioning, per-partition translation, attribute and `$cap`
   copying, dropping the bitcode round trip.

**Ceiling:** about 20 s of the current 44 s. That is translation 6.7 s, serialize 3.7 s, the
serial LLVM passes about 3.6 s, the IPSCCP prologue 6.2 s, and the per-worker re-parse.

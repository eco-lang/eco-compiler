# Kernel-Opt 03: eco.value.eq inline word-equality fast path

**Status: IMPLEMENTATION-READY v2 — 2026-08-10.** (deepened from OUTLINE v1; anchors
re-verified against the tree). Derived from design_docs/kernel-boundary-reduction.md
Q4.3 (lines 837-884), the Stage-7a dynamic census
(design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt) and the static
callsite census (design_docs/kernel-boundary/callsite-census-self-compile.txt).

## Files touched

| File | Change |
|---|---|
| `elm-kernel-cpp/src/core/UtilsExports.cpp` | P0: `ECO_VALUE_EQ_CENSUS` arm counters + atexit dump at the top of `Elm_Kernel_Utils_equal` (:107-109) / `_notEqual` (:111-113); reverted before P2 lands |
| `test/elm/src/EqDepthCutoffTest.elm` | P1 (new): golden pinning `eqHelp`'s `depth > 100 -> true` (Utils.cpp:566-569) |
| `runtime/src/codegen/Ops.td` | P2: new `Eco_ValueEqOp` def after `Eco_StringCmp3Op` (ends :2793, before the section-12 banner at :2795) |
| `runtime/src/codegen/Passes/EcoToLLVMArith.cpp` | P2: `ValueEqOpLowering` (marker call) next to `StringCmp3OpLowering` (:1134-1149); add to `populateEcoArithPatternsWithRuntime` (:1242-1258, after the `StringCmp3OpLowering` line at :1257) |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | P2: **declaration only** — `mlir::LLVM::LLVMFuncOp getOrCreateValueEqMarker(mlir::OpBuilder &) const;` next to the `getOrCreateUtilsEqual` decl (:689). No symbol constant here (see §2.2) |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | P2: define `getOrCreateValueEqMarker` next to `getOrCreateUtilsEqual` (:910-914); register in `materializeAllRuntimeDecls` (:1262); P4: flip `getOrCreateUtilsEqual` to `gcLeaf=true` (:913) |
| `runtime/src/codegen/EcoBackend.cpp` | P2: `expandValueEqFastPath(Module&)` next to `expandInlineDerefs` (:874-926); call it in `runEcoBackend` between the scratch gc-leaf loop (:2511-2515) and `expandInlineDerefs(m)` (:2517); P4: the `gc-leaf-function` stamp on `Elm_Kernel_Utils_equal` |
| `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` | P3: `ValueEq`/`BoolEq` constructors (:27-53), `utilsIntrinsic` arms (:563-644), `intrinsicResultMlirType` (:71-150), `intrinsicOperandTypes` (:155-253), `generateIntrinsicOp` (:773-981), new `intrinsicPostOps` + `admissibleIntrinsic`, **plus the module `exposing` list (:1) and the `@docs` line (:8)** |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | P3: thread `admissibleIntrinsic` + `intrinsicPostOps` through the two argType-carrying intrinsic sites (:3725-3747, :4199-4220). The third `kernelIntrinsic` site (:775) passes `argTypes = []` and can never match the new arms — leave it alone |
| `compiler/src/Compiler/Generate/MLIR/Patterns.elm` | P3: `Test.IsStr` (:266-290) emits `eco.value.eq` instead of `Ops.ecoCallNamed "Elm_Kernel_Utils_equal"` (:284-285) + `Intrinsics.unboxToType` (:287-288) |
| `compiler/src/Compiler/Eco/Config.elm` | P3: `valueEq : Bool` field appended LAST to `EcoConfig` (:34-48), `valueEq = False` last in `default` (:292-339), decoder entry last in `decoder` (:346-361), `hash` token `veq=1` (:540+) |
| `compiler/src/Builder/Eco/Config.elm` | P3: `ECO_VALUE_EQ` env override (`applyValueEqOverride`), appended after the last `Task.andThen` link (`ECO_BORROW_OPT`, :260-264) |
| `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp` | P3: `CaseStringToScfIfChainPattern` emits `eco.value.eq` under `ECO_VALUE_EQ_STRCASE` (:794-798, :832-840); `ensureEqualDeclared` (:762-774) + its call (:750) stay for the switch-off path and the stale comment at :1133 is updated |
| `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` | P3: `lowerStringCase` emits the `__eco_value_eq` marker instead of `getOrCreateUtilsEqual` + icmp under the same switch (:411-412, :476-487) |
| `test/codegen/value_eq_fastpath.mlir` | P2/P4 (new): 3-RUN fixture (marker / expanded diamond / JIT behavior), modelled on `inline_alloc_tuple.mlir` |
| `test/elm/src/EqBoxedFastPathTest.elm` | P3 (new): behavior golden across list/tuple/record/custom/string/Bool/Nothing/`[]` |
| `design_docs/kernel-boundary/value-eq-arm-census-stage7a.txt` | P0 (new): archived census output |
| `design_docs/invariants.csv` | P6: new `CGEN_076` row for the op + expansion contract |

## Flag & rollback

Four switches; **every one of them is default OFF/inert at land**, so a flag-off build is
byte-identical to the pre-feature tree with NO carve-outs. (Repo rule: compiler emission
gates behind Config.elm; backend/runtime gates behind env vars.)

1. **Compiler emission** — `Config.valueEq : Bool`, **default `False`**, env `ECO_VALUE_EQ=1|0`
   (`Builder/Eco/Config.elm`, exactly the `applyAggPromoteOverride` shape at :267-291).
   ARTIFACT-AFFECTING: hash token `veq=1` appended only when enabled, so flag-off builds
   share every pre-feature cache (the `cafd=1` pattern, Config.elm:576-584). Off ⇒ the Elm
   backend emits today's `eco.call @Elm_Kernel_Utils_equal` and no `eco.value.eq` exists.
2. **Synthesized string-`case` sites** — `ECO_VALUE_EQ_STRCASE`, **default `0` at land**.
   These two rewrites (P3.4 `EcoControlFlowToSCF`, P3.5 `EcoToLLVMControlFlow`) live in the
   BACKEND, below the front end's Config flag, so they need their own env switch or the
   feature would not be default-off. `=0` keeps today's `Elm_Kernel_Utils_equal` +
   `UnboxOp`/`ICmpOp` shape verbatim (`ensureEqualDeclared` therefore stays in the tree);
   `=1` emits `eco.value.eq` / the `__eco_value_eq` marker. Flipped to `1` in Phase 6 once
   the gates are green.
3. **Backend inline arms** — `ECO_VALUE_EQ_INLINE`, **default `1` once P2 lands**, and inert
   until switch 1 or 2 turns on (nothing produces a marker otherwise). `=0` makes
   `expandValueEqFastPath` expand each marker to a bare call + `icmp eq` against the True
   word — i.e. today's shape, no diamond — so an A/B isolates the arms from the op.
4. **gc-leaf stamp** — `ECO_VALUE_EQ_GCLEAF`, **default `0` until kernel-opt-07 Phase 5 has
   deleted the fprintf** (07's phase numbering: Phase 5 "delete the trace (R2)"; Phase 2 is
   the KernelSigs shim), then `1`. `=0` ⇒ `Elm_Kernel_Utils_equal` keeps no attrs and RS4GC
   statepoints the fallback call normally (still correct — see Trap 6). Note the fprintf is
   NOT itself a gc-leaf hazard (kernel-opt-08 Traps: "a side effect but not a GC hazard");
   the switch is default-off because a lying gc-leaf declaration is silent heap corruption
   and because kernel-opt-08 owns the permanent single-channel stamp (see Phase 4).

Revert story: P2-P4 are additive. Reverting = set `valueEq = False` in `Config.default`
(one line; recompiles to byte-identical pre-feature MLIR, verified by the flag-off inertness
gate) and, if the runtime must also revert, `ECO_VALUE_EQ_STRCASE=0 ECO_VALUE_EQ_INLINE=0
ECO_VALUE_EQ_GCLEAF=0`. Full excision = drop the `Eco_ValueEqOp` def + its lowering +
`expandValueEqFastPath` + the two `ECO_VALUE_EQ_STRCASE` branches.

## Goal

Replace boxed `Utils_equal`/`notEqual` calls with an `eco.value.eq : (!eco.value,
!eco.value) -> i1` op whose lowering inlines the two word-level short-circuits
(pointer-equal / embedded-constant mismatch) and falls back to a gc-leaf call for genuine
structural comparison. Deletes per-op work (the call + argument marshalling + its statepoint)
on every arm-1/arm-2 hit; the fallback keeps exact kernel semantics.

## Evidence

- **Dynamic:** `Elm_Kernel_Utils_equal` = 282,801,940 calls (row 6 of 98,
  kernel-census-dynamic-stage7a.txt:6); `Elm_Kernel_Utils_notEqual` = 4,155,093 (:21).
  Unlike `Utils_compare` (retired by the Aug 10 cmp series), these rows are still LIVE.
- **Static:** 1,357 sites (`callsite-census-self-compile.txt:4`, #4 by site count) + 63
  `notEqual` sites (:26) — PLUS calls synthesized by the string-pattern case lowering itself
  (EcoToLLVMControlFlow.cpp:411-412 + :476-487; EcoControlFlowToSCF.cpp:794-798 + :832-840),
  so the shipped binary calls `equal` from more places than the static census counts.
- **Word-level facts (ALL re-verified in the tree 2026-08-10):**
  - `eqHelp` short-circuits on pointer equality first: `if (a == b) return true;` —
    **Utils.cpp:521-523** (design doc said :514-516). This short-circuit sits ABOVE every
    tag dispatch, including the `Tag_Closure -> false` arm at :733-735, so arm 1 is
    *literally* the kernel's own first line: there is no shape (closures included) on which
    a word-equal pair disagrees with `Elm_Kernel_Utils_equal`.
  - `equalRespectingConstants` — **UtilsExports.cpp:88-105** (doc said :47-58): `if
    (isConstantBits(aBits) || isConstantBits(bBits)) return aBits == bBits;` at :101-103.
    `isConstantBits(b)` is *exactly* `hpFromBits(b).ptr_ind != 0`, i.e. **bit 2 of the word**
    — Heap.hpp:323. `PTR_IND_BIT` = 2 at **Heap.hpp:221** (doc said :223). Golden words
    False `0x4` / True `0x5` / Empty `0x6`: `Constant` enum **Heap.hpp:186-190**, golden-word
    note **:212-217**.
  - Boxed-Bool decode: bit 0 of a Bool constant word IS the i1 (`boolValueBits`,
    **Heap.hpp:335-337**; layout comment :180). `encodeBoxedBool` only ever produces
    `0x4`/`0x5` (ExportHelpers.hpp:79-81), so `icmp eq %r, 0x5` decodes it exactly.
  - **The whole equal family is GC-allocation-free.** `eqHelp` **Utils.cpp:521-740**; the
    only allocating `alloc::` calls in Utils.cpp are `alloc::custom` at :35/:37/:39
    (one-time `initOrderSingletons`) and `alloc::emptyString()` at :830 (in `append`, not
    equality) — every other `alloc::` on the eq paths is a predicate/view. `dictEq` scratch
    is a C++ `std::vector<Custom*>` (**:776**, doc said :746). `StringOps::equal`
    **StringOps.hpp:1486-1533** — memcmp/segment walk, `std::vector<SegView>` scratch only.
    `alloc::ListCursor` is *documented* as safe for "the read-only walkers
    (eq/compare/toString/length) which never allocate mid-walk" — **HeapHelpers.hpp:812-821**
    (doc comment; `struct ListCursor` itself starts at :822).
  - **Depth is nesting depth, not spine length.** The only `depth + 1` is
    `eqUnboxableSlot`'s boxed-slot recursion (**Utils.cpp:125**); `Tag_Cons` walks the spine
    *iteratively* at the same depth (:625-654). So a 10⁶-element list never trips the cutoff;
    only ≥101 levels of nested boxed structure do.
- Typed Int/Float/Char equality is already intrinsic (`utilsIntrinsic`,
  **Intrinsics.elm:563-644**, doc said :560-620) — what reaches the kernel is strings, lists,
  tuples, records, customs, Dict-by-content **and Bool**: there is *no* `MBool` arm in
  `utilsIntrinsic`, so `a == b` on two Bools boxes both to `0x4`/`0x5` and calls the kernel
  (this is pure arm-1/arm-2 traffic, and P3a kills it outright with `eco.bool.xor`).
- **Precedent that a `Pure` eco op may lower to a plain (even non-gc-leaf) call with no
  EcoGCPrepare involvement:** `eco.string.cmp3` (Ops.td:2775-2793) lowers to
  `Elm_Kernel_Utils_cmp3`, explicitly NOT gc-leaf (EcoToLLVMRuntime.cpp:952-958), and is
  neither an `isGroupBarrier` nor an `isCallSafepoint` (EcoGCPrepare.cpp:110-140). Shipped
  and green. `eco.value.eq` inherits that shape.

## Outcome — COMPLETE 2026-08-12 (benchmarks/kernel-opt.md Run K)

**All seven phases are done and the item is DEFAULT-ON.** The Phase-0 census below measured
the inline arms at 6.47% against this plan's 25% bar; that bar was overruled by decision --
the loop's veto criterion is a wall REGRESSION, not a plan-internal payoff gate -- and the
item was built in full.

- **P1** `test/elm/src/EqDepthCutoffTest.elm` pins the depth-100 cutoff and the iterative
  `Tag_Cons` spine walk, so the op provably does not move the boundary it inherits.
- **P2** op + declare-only marker + the three-arm pre-RS4GC expansion.
- **P3** emission: `ValueEq`/`BoolEq` ctors with the `boxedComparable` whitelist,
  `Patterns.elm`'s `IsStr` test, and BOTH synthesized string-`case` sites
  (`EcoControlFlowToSCF.cpp`, `EcoToLLVMControlFlow.cpp`) under `ECO_VALUE_EQ_STRCASE`.
- **P4** `Elm_Kernel_Utils_equal`'s declaration carries `gc-leaf-function`.
- **P5** closed by kernel-opt-06's 64-site residue measurement.
- **P6** defaults flipped + **`CGEN_076`** appended to invariants.csv.

**Emission is 100%:** `Utils_equal` 1392 -> 0, `Utils_notEqual` 60 -> 0, `eco.value.eq`
+1452 -- an exact 1:1. Wall **-1.84%**, inside the +/-2.8% band, so recorded FLAT rather than
claimed as a win; that is consistent with the census, since most sites still reach arm 3.
Gates: E2E **1642/1642 in all three switch states** and again default-on.

**Two deviations from the plan text**, both to avoid duplicating mechanisms that sibling
items had already built:
1. `admissibleIntrinsic` was NOT added; its job is done by `Expr.gateIntrinsic`, which
   already takes `(ctx, argsWithTypes, intrinsic)` -- exactly the signature required, and the
   settled gating idiom since kernel-opt-01/04.
2. `intrinsicPostOps` was NOT added; the `notEqual` negation is emitted by
   `generateIntrinsicOps`, the multi-op channel kernel-opt-06 built, via a shared
   `emitEqMaybeNegated` helper. One mechanism instead of three.

**Outstanding:** `ECO_VALUE_EQ_STRCASE` ships **default-off**. Both halves are implemented
and proven correct by the third gate leg, but no wall A/B was run for them; do not default
them on without one.

## The Phase-0 census (retained -- it is still the evidence about payoff)

**The census killed the arms.** Executed on the cold Stage-7a self-compile
(archived at `design_docs/kernel-boundary/value-eq-arm-census-stage7a.txt`):

```
total=158657944 bool=646 word=10204820 const=63114 slow=148389364
nonbool_total=158657298 word_pct=6.432 const_pct=0.040 slow_pct=93.528
```

`word_pct + const_pct = 6.47%` against this plan's own **25%** bar — it fails by 3.9x, so
per §Phase 0's decision point the inline arms are **measured dead** and must not be built.
Two further corrections the census forces:

- **The population is 44% smaller than this plan assumed.** §Evidence quotes 282,801,940
  calls; the measured total is **158,657,944**. The Aug-10 compare series and kernel-opt-06
  removed the difference. Do not requote the 282.8M figure.
- **P3a's entire target is 646 calls** — 0.0004% of traffic. §Expected impact calls P3a "a
  pure deletion" and "unconditionally better", which is still true as code quality (one
  `arith.xori` instead of a call), but its dynamic payoff is nil. It was not built.

**P2/P4 were also not built, which departs from the <25% branch's letter.** That branch says
to land `eco.value.eq` anyway with `ECO_VALUE_EQ_INLINE=0`, for the gc-leaf stamp, the
group-barrier relief and a CSE-able `Pure` producer. Each of those three has since been
answered elsewhere:

1. **gc-leaf is subsumed by kernel-opt-08**, which is the very next item. `(Utils, equal)` is
   in kernel-opt-07's A1 stampable 14 (`gcAlloc = GcNone`, `callsBackIntoElm = False`), so 08
   stamps `Elm_Kernel_Utils_equal` from the facts table with no help from here. This plan's
   own §Phase 4 already says its stamp is transitional and is deleted when 08 lands — so
   building it now is scaffolding for a bridge that arrives in one item's time.
2. **Group-barrier relief is nil.** kernel-opt-05 §1a.4 and kernel-opt-09 both established
   that `isGroupBarrier` is effectively dead: `processBlock` calls `flushGroup()` for every
   non-allocation op before consulting it, so an `arith.constant` splits a group exactly as an
   `eco.call` does.
3. **The `Pure` CSE-able producer** is the one live benefit, and it is speculative: its only
   consumer is kernel-opt-10's MLIR CSE, which is itself census-gated and has not run.

**Reopen condition.** If kernel-opt-10's Phase-0 census finds a real duplicate-equality pool,
build P2 then — the op, the marker and the lowering are fully specified above and nothing in
the tree has invalidated them. Also reopen if a future workload shifts `word_pct + const_pct`
above 25%; the census is one rebuild plus one cold run.

**Phase 5 is separately closed.** kernel-opt-06 measured the surviving boxed comparison
population at **64 sites** (lt 14, le 0, gt 10, ge 2, compare 38) against Phase 5's `>200`
threshold, and the dynamic clause could not be measured because the per-symbol census is not
in the tree — so per this plan's own wording both conditions are unmet.

**Landed from this item:** the census result and its archive (instrumentation reverted,
verified zero residue in `UtilsExports.cpp`), **and Phase 2 in full** — see below.

### Phase 2 BUILT anyway — 2026-08-11, by explicit decision

The NO-GO reasoning above argued against building P2 as scaffolding. That was overruled:
P2 is required groundwork for later plans and has been built in full.

Landed, runtime-only, with **no Elm emission** (Phase 3 remains unbuilt):

- `Eco_ValueEqOp` (`Ops.td`), `[Pure, Commutative]`. `Pure` is licensed precisely because
  kernel-opt-07 deleted the tag-mismatch stderr trace — that dependency is now discharged,
  not pending.
- `getOrCreateValueEqMarker` (decl + definition + **`materializeAllRuntimeDecls`**, which is
  the easily-missed one: a create after `freeze()` is an assert, not a clean error).
- `ValueEqOpLowering` in `EcoToLLVMArith.cpp`, emitting the declare-only `__eco_value_eq`.
- `expandValueEqFastPath` in `EcoBackend.cpp`, expanding the three-arm diamond pre-RS4GC and
  erasing the declaration; plus the `ECO_VALUE_EQ_GCLEAF` stamp block, deliberately placed
  ABOVE the marker early-return so modules that call `Elm_Kernel_Utils_equal` without any
  `eco.value.eq` still get stamped.
- `test/codegen/value_eq_fastpath.mlir`, three legs. This is the op's ONLY exercise while
  Phase 3 is unbuilt, and all three arms are pinned by the JIT leg: word equality, the
  ptr_ind constant test (mixed and both-constant), and the kernel call decoded against the
  True word 0x5.

Gates: fixture green on all three legs; full E2E **1640/1640**.

**Left for whoever lands Phase 3:** the census says the shipped default should be
`ECO_VALUE_EQ_INLINE=0` (bare call + icmp), since the inline arms are worth 6.47% against a
25% bar. The helper currently defaults ON because nothing emits the op, so the default is
moot and the fixture is more valuable exercising the diamond. Flip it when emission lands.

## Approach

### Phase 0 — arm-hit census (one day, no product change)

The expectation that Bool/constant-heavy code mostly hits arms 1-2 is UNMEASURED. Measure
before building the lowering.

**Mechanism** (modelled verbatim on the closure census, RuntimeExports.cpp:754-826 — the
`std::atomic` table at :754-769, the `std::atexit(closureStatsDumpImpl)` install at :819, the
`closureStatsRecord` entry point at :828): an anonymous namespace in
`elm-kernel-cpp/src/core/UtilsExports.cpp`, **inserted between `using namespace Elm::Kernel;`
(:9) and `extern "C" {` (:11)** — it must be outside the `extern "C"` block and after the
`using` directives, because `isConstantBits`/`isEmptyBits` are `Elm::` free functions
(Heap.hpp:323 / :327-330) reached through `using namespace Elm;` at :8.

Add `#include <atomic>`, `<cstdio>` (fprintf/fflush), `<cstdlib>` (getenv/atexit) and
`<cstring>` (strcmp) — the file today includes only KernelExports.h (:3), ExportHelpers.hpp
(:4), Utils.hpp (:5) and allocator/StringOps.hpp (:6), none of which guarantee those.

**Four buckets, not three.** Arm-1 hits are split into `bool` (both operands are Bool
constant words) and `word` (everything else word-equal), because **P3a deletes the Bool
traffic outright** — counting it toward the arms' payoff would inflate the decision
criterion with calls that will not exist by the time the arms ship. A Bool constant word is
`isConstantBits(w) && !isEmptyBits(w)` (Heap.hpp:332-334 states exactly this predicate).

```cpp
namespace {
std::atomic<uint64_t> g_veq_bool{0}, g_veq_word{0}, g_veq_const{0}, g_veq_slow{0};
std::atomic<bool>     g_veq_dumped{false};

inline bool veqIsBoolWord(uint64_t w) {          // Heap.hpp:332-334
    return Elm::isConstantBits(w) && !Elm::isEmptyBits(w);
}

void veqDumpImpl() {
    if (g_veq_dumped.exchange(true)) return;
    uint64_t bl = g_veq_bool .load(std::memory_order_relaxed);
    uint64_t w  = g_veq_word .load(std::memory_order_relaxed);
    uint64_t c  = g_veq_const.load(std::memory_order_relaxed);
    uint64_t s  = g_veq_slow .load(std::memory_order_relaxed);
    uint64_t t  = bl + w + c + s;
    uint64_t nb = t - bl;                        // the post-P3a population
    std::fprintf(stderr,
        "[value-eq-census] total=%llu bool=%llu word=%llu const=%llu slow=%llu "
        "nonbool_total=%llu word_pct=%.3f const_pct=%.3f slow_pct=%.3f\n",
        (unsigned long long)t, (unsigned long long)bl, (unsigned long long)w,
        (unsigned long long)c, (unsigned long long)s, (unsigned long long)nb,
        nb ? 100.0 * w / nb : 0.0, nb ? 100.0 * c / nb : 0.0, nb ? 100.0 * s / nb : 0.0);
    std::fflush(stderr);
}
bool veqInit() {
    const char* e = std::getenv("ECO_VALUE_EQ_CENSUS");
    if (!e || !*e || std::strcmp(e, "0") == 0) return false;
    std::atexit(veqDumpImpl);
    return true;
}
inline bool veqEnabled() { static const bool on = veqInit(); return on; }

inline void veqRecord(uint64_t a, uint64_t b) {          // classify, do not decide
    if (!veqEnabled()) return;
    if (veqIsBoolWord(a) && veqIsBoolWord(b))     g_veq_bool .fetch_add(1, std::memory_order_relaxed);
    else if (a == b)                              g_veq_word .fetch_add(1, std::memory_order_relaxed);
    else if (Elm::isConstantBits(a) || Elm::isConstantBits(b))
                                                  g_veq_const.fetch_add(1, std::memory_order_relaxed);
    else                                          g_veq_slow .fetch_add(1, std::memory_order_relaxed);
}
} // namespace
```

Insert one `veqRecord(a.toBits(), b.toBits());` as the FIRST statement of
`Elm_Kernel_Utils_equal` (UtilsExports.cpp:107-109) and of `Elm_Kernel_Utils_notEqual`
(:111-113). Apart from the Bool split, the classifier mirrors the op's arms exactly (arm 1 =
`a == b`, arm 2 = `isConstantBits(a) || isConstantBits(b)` — bit-identical to
`equalRespectingConstants`, UtilsExports.cpp:101-103), so its buckets *are* the arm hits.
Nothing emits `eco.value.eq` yet in Phase 0, so 100% of the traffic still reaches the kernel
and the census sees the whole population.

**Run it** (cold Stage 7a self-compile is the reference workload — the counters live in the
kernel linked into the *tested binary*, and the run is the binary compiling the compiler
front-end; command copied from `benchmarks/kernel-opt.md:96-130`, itself the Stage-7a
invocation at `compiler/CMakeLists.txt:478-491`):

```bash
cd /work
BK=build/compiler/build-kernel
# 1. rebuild the kernel + the tested binary with the counters in it.
#    (Ninja is env-blind: delete the Stage-5 outputs so it really re-runs.)
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"
cmake --build build --target eco-compiler 2>&1 | tee /tmp/veq_build.txt
# 2. one cold run. eco-stuff MUST be deleted; ~/.eco must NOT be.
rm -rf "$BK/eco-stuff"
( cd "$BK" && ECO_MONO_ENGINE=subst ECO_VALUE_EQ_CENSUS=1 \
    ./bin/eco-compiler make --optimize --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/veq-census-out.mlir /work/compiler/src/Terminal/Main.elm \
        > /tmp/veq_census.stdout 2> /tmp/veq_census.log )
grep '\[value-eq-census\]' /tmp/veq_census.log
cp /tmp/veq_census.log design_docs/kernel-boundary/value-eq-arm-census-stage7a.txt
```

**Decision point (criterion + both branches).** The criterion is computed over
`nonbool_total`, i.e. the population that still exists after P3a:
- `word_pct + const_pct >= 25%` → **build the full inline lowering** (P2-P4 as written). At
  25% of the non-Bool share of 282.8M calls that is tens of millions of deleted
  calls+statepoints, comparable in magnitude to the wins that DID move wall.
- `word_pct + const_pct < 25%` → **P2/P4 only, arms skipped.** Land `eco.value.eq` with
  `ECO_VALUE_EQ_INLINE=0` as the *default* expansion (bare call + `icmp`), take the gc-leaf
  + un-barriered-op benefits, and record in this file that the arms were measured dead. The
  op still buys: no `eco.call` group barrier, CSE-able `Pure` producer for kernel-opt-10/13,
  and one declaration channel for the gc-leaf stamp.
- Either way P3a (Bool → `eco.bool.xor`) proceeds: it is unconditionally better and needs no
  census. Record `bool=` separately — it is P3a's own expected-deletion count.

**Acceptance:** census file archived; `word/const/slow` percentages recorded in the Expected
impact section below; the census instrumentation **reverted** (`git checkout
elm-kernel-cpp/src/core/UtilsExports.cpp`) before Phase 2 — it is a measurement, not a
shipped counter.

### Phase 1 — pin the depth-100 cutoff (precondition B)

`eqHelp` returns `true` at nesting depth > 100 (**Utils.cpp:566-569**) while `cmp` has no
such limit, so `==` and `compare == EQ` can disagree on deep values. The op INHERITS this;
it must never silently change it. Pin it first.

New file `test/elm/src/EqDepthCutoffTest.elm` (E2E tests are auto-discovered from
`test/elm/src` by `discoverTests`, ElmE2ETestBase.hpp:1089-1106 — every `*.elm` with a
top-level `main`, no registration step; assertions are `-- CHECK:` lines matched against
stdout, parsed by `test/CheckPatterns.hpp`. Shape copied verbatim from
`test/elm/src/BoolXorTest.elm`).

```elm
module EqDepthCutoffTest exposing (main)

{-| Pins eqHelp's depth cutoff (elm-kernel-cpp/src/core/Utils.cpp:566-569):
`depth > 100 -> return true`, i.e. two DIFFERENT values nested more than 100
levels deep compare EQUAL. `compare` has no such cap, so `==` and
`compare == EQ` disagree there; eco.value.eq inherits this and must not move
it.

Depth increments ONLY through eqUnboxableSlot's boxed-slot recursion
(Utils.cpp:125). `Wrap Nest` is a boxed slot, so each Wrap costs one level;
`Leaf Int` is an UNBOXED Int field (REP: Int/Float/Char are the only unboxed
heap fields), compared in place with no recursion. So `nest N` bottoms out in
an eqHelp call at depth N and the predicted flip is between N=100 (False) and
N=101 (True). `Tag_Cons` walks the spine ITERATIVELY at one depth
(Utils.cpp:625-654), which is what `longList` pins.
-}

-- CHECK: shallow: False
-- CHECK: belowLimit: False
-- CHECK: aboveLimit: True
-- CHECK: longList: False

import Html exposing (text)

type Nest = Leaf Int | Wrap Nest

nest : Int -> Int -> Nest
nest n leaf = if n <= 0 then Leaf leaf else Wrap (nest (n - 1) leaf)

main =
    let
        _ = Debug.log "shallow"    (nest 3   1 == nest 3   2)
        _ = Debug.log "belowLimit" (nest 90  1 == nest 90  2)
        _ = Debug.log "aboveLimit" (nest 120 1 == nest 120 2)
        _ = Debug.log "longList"   (List.range 1 5000 == List.range 1 4999)
    in
    text "done"
```

90 and 120 are deliberately clear of the boundary so the test cannot flake on a
one-level accounting difference (e.g. if a future layout change boxes the `Leaf Int`
field, every depth shifts by one but both assertions still hold).

**Locating the exact flip point (one extra step, done once).** Add a temporary
`Debug.log "n<K>"` line per `K` in 98..103 to the same file, run the suite ONCE, read the
flip from the output, then delete the probes and record the measured boundary in the module
doc comment:

```bash
TEST_FILTER=EqDepthCutoff cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
grep -E '^n(98|99|100|101|102|103): ' /tmp/test_output.txt
```

**Acceptance:** `TEST_FILTER=EqDepthCutoff cmake --build build --target full` green, on the
CURRENT kernel (before any op work), with the measured boundary recorded in the doc comment.
Re-run unchanged after P2/P3/P4 — the op must not move the flip point.

### Phase 2 — the op, the marker, and the LLVM expansion (runtime only, no emission yet)

Nothing emits `eco.value.eq` yet; this phase is exercised only by the new `.mlir` fixture.

**2.1 — TableGen def.** `runtime/src/codegen/Ops.td`, immediately after `Eco_StringCmp3Op`
(ends :2793) and before the "12. Reference Counting Placeholders" banner (:2795-2803).
Modelled on `Eco_IntEqOp` (:2273-2285) for the i1 result — note it, too, gets away with
`assemblyFormat = "... type($lhs)"` because `Eco_Bool` is a fixed I1 constraint and so needs
no `-> type($result)` — and on `Eco_StringCmpOrderOp` (:2759-2773) for the `!eco.value`
operands + the immutability rationale (Ops.td:2753-2757) that licenses `Pure`.

> **`Pure` is blocked on kernel-opt-07 Phase 5** ("delete the trace (R2)")**.** `Pure` in MLIR is
> `NoMemoryEffect + AlwaysSpeculatable`, which licenses CSE/DCE/speculation of the op.
> `Elm_Kernel_Utils_equal` today writes to stderr on the tag-mismatch path
> (Utils.cpp:557-562), so dropping or merging calls is observable. Do not land 2.1 with
> `Pure` until that hunk is deleted — see Phase 4 Precondition A and the Dependencies
> section, which make 07 a hard blocker for Phase 2 as well as Phase 4.

```tablegen
def Eco_ValueEqOp : Eco_Op<"value.eq", [Pure, Commutative]> {
  let summary = "Structural equality of two boxed values; returns i1";
  let description = [{
    Bit-exact replacement for a call to `Elm_Kernel_Utils_equal` followed by a
    boxed-Bool decode. Operands are boxed (REP_ABI_001), the result is the
    SSA i1 Bool.

    Lowers to the declare-only marker `__eco_value_eq`, which
    `expandValueEqFastPath` (EcoBackend.cpp) expands pre-RS4GC into:
      (1) word equality      -> true   (Utils.cpp:521-523 + the constant guard)
      (2) either word has bit 2 (ptr_ind) set -> false
          (exactly equalRespectingConstants, UtilsExports.cpp:101-103)
      (3) otherwise a gc-leaf call to Elm_Kernel_Utils_equal, decoded by
          comparing against the True word (0x5).

    `Pure` is sound for the same reason as eco.string.cmp_order: every Eco heap
    value is immutable after construction, and SSA dominance already prevents
    motion above the operands' defs. It additionally requires the tag-mismatch
    stderr trace to be gone (kernel-opt-07 Phase 5, Utils.cpp:557-562).

    ```mlir
    %eq = eco.value.eq %a, %b : !eco.value
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}
```

> **Closure note (corrected 2026-08-10 — the outline's claim was backwards).** `eqHelp`'s
> `if (a == b) return true;` (Utils.cpp:521-523) runs BEFORE the tag switch, so two
> pointer-equal closures already return `true` today; the `Tag_Closure -> false` arm
> (:733-735) is reached only for two *distinct* closure pointers, which arm 1 does not
> claim. **Arm 1 therefore never disagrees with the kernel, closures included.** `MFunction`
> is nonetheless excluded from the P3 `boxedComparable` whitelist because Elm's type checker
> forbids comparing functions (so no admissible program produces such a call) and because a
> function value's ABI may be a PAP rather than a plain `!eco.value` — whitelist discipline,
> not a divergence fix.

**2.2 — the declare-only marker.**

**Symbol naming — use the string literal `"__eco_value_eq"` in both places, not a shared
constant.** The outline placed a `kValueEqSym` constant in `Passes/EcoToLLVMInternal.h`; that
is wrong twice over. (a) `kSlotToHPtrSym`/`kHPtrToSlotSym` do NOT live there — they are
`inline constexpr const char kSlotToHPtrSym[] = ...` in `Passes/EcoSlotCastBarriers.h:31-32`,
namespace `eco`. (b) `EcoBackend.cpp` does not include `EcoToLLVMInternal.h` at all (its
includes are `EcoBackend.h`, `LoweringStats.h`, `Passes/EcoPtrIntVerify.h`,
`Passes/EcoSlotCastBarriers.h`, :3-7), so a constant declared there would be invisible to
`expandValueEqFastPath`. The two markers this plan is modelled on both use plain literals on
both sides — `"__eco_resolve_fwd"` (EcoToLLVMRuntime.cpp:630 / EcoBackend.cpp:875, :1173,
:1270, :1434) and `"__eco_alloc_inline"` (EcoToLLVMRuntime.cpp:655). Do the same, and put a
one-line cross-reference comment at each site.

`Passes/EcoToLLVMInternal.h`: the ONLY edit is one method declaration next to the
`getOrCreateUtilsEqual` decl (:689):
`mlir::LLVM::LLVMFuncOp getOrCreateValueEqMarker(mlir::OpBuilder &builder) const;`

`Passes/EcoToLLVMRuntime.cpp`, immediately after `getOrCreateUtilsEqual` (:910-914). `I1_TY`
and `HPTR_TY` are the file's own macros (:161, :164) and expand against the `ctx` already in
scope in every `getOrCreate*`:

```cpp
// eco.value.eq marker: __eco_value_eq(a: hptr, b: hptr) -> i1. DECLARE-ONLY —
// expandValueEqFastPath (EcoBackend.cpp, which spells the same literal) expands
// every call at the very top of runEcoBackend, before ANY RS4GC flavour, and
// then erases this declaration; no definition ever exists and no call reaches
// codegen. gc-leaf matches the other declare-only markers (__eco_resolve_fwd
// :630, __eco_alloc_inline :655, __eco_slot_to_hptr :895) and is belt-and-braces
// only. NEVER add memory(none)/speculatable/willreturn: gc-leaf is the ONLY
// attribute a decl carrying !eco.value may hold pre-RS4GC (REP_LLVM_002; the
// bisected miscompile class is documented at :884-891).
LLVM::LLVMFuncOp EcoRuntime::getOrCreateValueEqMarker(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I1_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "__eco_value_eq", funcTy, /*gcLeaf=*/true);
}
```

**Registration checklist for `__eco_value_eq`** (verified against how `elm_array_push_int`
is wired — JsArrayExports.cpp:745 definition + KernelExports.h:281 decl +
RuntimeSymbols.cpp:767 `KERNEL_SYM` + EcoToLLVMRuntime.cpp:1015 MLIR decl +
materializeAllRuntimeDecls:1269 — and against the declare-only `__eco_slot_to_hptr`, which
was grepped and appears in **neither** KernelExports.h nor RuntimeSymbols.cpp):

| Point | Needed? |
|---|---|
| `EcoToLLVMInternal.h` method decl at :689 (no symbol constant — see above) | YES |
| `EcoToLLVMRuntime.cpp` `getOrCreate*` definition | YES |
| `EcoToLLVMRuntime.cpp:1262` `materializeAllRuntimeDecls` | **YES — mandatory.** `freeze()` (EcoToLLVM.cpp:352) turns a later create into an assert (getOrCreateFunc:135-137) |
| `elm-kernel-cpp/src/KernelExports.h` | NO — declare-only, no C++ definition |
| `runtime/src/codegen/RuntimeSymbols.cpp` `KERNEL_SYM` | NO — never resolved by the JIT; every call is expanded away |
| Conversion-target legality | NO — `bodyTarget.addIllegalDialect<EcoDialect>()` (EcoToLLVM.cpp:405) makes the new op illegal automatically; supplying the pattern is the whole registration |

Because every runtime decl is pre-materialized, the unused-decl prune at
**EcoToLLVM.cpp:584-604** (`SymbolUserMap` + `fn.isExternal() && useEmpty` → `fn.erase()`) is
what keeps `__eco_value_eq` out of modules that never emit the op — which is also why
`expandValueEqFastPath`'s `m.getFunction(...)` legitimately returns null and must early-out.

**2.3 — the lowering pattern.** `Passes/EcoToLLVMArith.cpp`, next to `StringCmp3OpLowering`
(:1134-1149), same runtime-carrying shape:

```cpp
// eco.value.eq -> the declare-only __eco_value_eq marker. The fast/slow diamond
// cannot be built here: this pattern runs inside the Stage 2 dialect conversion,
// which also lowers scf, so block surgery on a still-converting region is not
// available. Emitting a marker and expanding it at LLVM-IR level pre-RS4GC is the
// house idiom (HEAP_034 __eco_alloc_inline; P2 __eco_resolve_fwd).
struct ValueEqOpLowering : public OpConversionPattern<ValueEqOp> {
    const EcoRuntime &runtime;
    ValueEqOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                      const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ValueEqOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateValueEqMarker(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
        return success();
    }
};
```
and one line in `populateEcoArithPatternsWithRuntime` (:1242-1258, after the
`StringCmp3OpLowering` line at :1257):
`patterns.add<ValueEqOpLowering>(typeConverter, ctx, runtime);`

**2.4 — the expansion.** `runtime/src/codegen/EcoBackend.cpp`, a new static function next to
`expandInlineDerefs` (:874-926), using the same `IRBuilder` + `PHINode` idiom (this one needs
a 3-way phi, so it uses `BasicBlock::splitBasicBlock` + two fresh blocks rather than
`SplitBlockAndInsertIfThen`, which only builds a 2-way if-then). `PTR_IND_BIT` (Heap.hpp:221,
a `#define`) and `Elm::Const_True` (Heap.hpp:186-190, inside `namespace Elm` opened at :36 —
same qualification style as `Elm::Tag_Forward` at EcoBackend.cpp:906) come from
`../allocator/Heap.hpp`, already included at :55.

```cpp
static bool valueEqInlineEnabled() {                 // ECO_VALUE_EQ_INLINE=0 -> bare call
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_INLINE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}
static bool valueEqGcLeafEnabled() {                 // ECO_VALUE_EQ_GCLEAF=1 -> stamp (P4)
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_GCLEAF");
        return e && e[0] == '1' && e[1] == '\0';
    }();
    return on;
}

// Expand each `__eco_value_eq(a, b) -> i1` marker into the word-equality diamond.
// MUST run before EVERY RewriteStatepointsForGC flavour and before
// propagateGcFreeLeafAttrs (CGEN_072), so the fixpoint sees arm 3 as a call to a
// gc-leaf declaration rather than an unknown marker.
//
//   head: %same = icmp eq ptr addrspace(1) %a, %b
//         br %same, cont, test
//   test: %aw = ptrtoint %a ; %bw = ptrtoint %b            (REP_LLVM_001(d): the i64s
//         %any = icmp ne (and (or %aw, %bw), 4), 0          are consumed by or/and/icmp
//         br %any, cont, slow                               in this SAME block, which
//   slow: %r  = call @Elm_Kernel_Utils_equal(%a, %b)        EcoPtrIntVerify accepts
//         %rb = icmp eq %r, inttoptr(0x5)                   verbatim, :209-216)
//         br cont
//   cont: %res = phi i1 [true, head], [false, test], [%rb, slow]
static void expandValueEqFastPath(Module &m) {
    LLVMContext &ctx = m.getContext();
    Type *i1Ty = Type::getInt1Ty(ctx), *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t constBit = 1ULL << PTR_IND_BIT;                    // 0x4
    const uint64_t trueWord = constBit | (uint64_t)Elm::Const_True;   // 0x5

    Function *marker = m.getFunction("__eco_value_eq");
    // Arm 3 needs the decl; create it only when there is a marker to expand.
    FunctionCallee eqCallee;
    if (marker)
        eqCallee = m.getOrInsertFunction(
            "Elm_Kernel_Utils_equal", FunctionType::get(as1, {as1, as1}, false));

    // P4.2 — module-wide gc-leaf stamp. MUST sit ABOVE the marker early-return:
    // a module can call Elm_Kernel_Utils_equal with NO eco.value.eq in it (flag
    // off, or non-admissible call sites), and those modules need the stamp too.
    // getFunction, NOT getOrInsertFunction: never conjure the decl into a module
    // that does not reference it.
    if (Function *eqFn = m.getFunction("Elm_Kernel_Utils_equal"))
        if (valueEqGcLeafEnabled())
            eqFn->addFnAttr("gc-leaf-function");   // NEVER memory(none)/speculatable

    if (!marker) return;   // pruned by EcoToLLVM.cpp:584-604 when unused

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u)) calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *a = ci->getArgOperand(0), *b = ci->getArgOperand(1);
        IRBuilder<> b0(ci);
        if (!valueEqInlineEnabled()) {                       // A/B shape: today's codegen
            Value *r  = b0.CreateCall(eqCallee, {a, b}, "eq.r");
            Value *tc = b0.CreateIntToPtr(ConstantInt::get(i64Ty, trueWord), as1);
            ci->replaceAllUsesWith(b0.CreateICmpEQ(r, tc, "eq.res"));
            ci->eraseFromParent();
            continue;
        }
        BasicBlock *headBB = ci->getParent();
        Function   *F      = headBB->getParent();
        BasicBlock *contBB = headBB->splitBasicBlock(ci, "eq.done");
        BasicBlock *testBB = BasicBlock::Create(ctx, "eq.test", F, contBB);
        BasicBlock *slowBB = BasicBlock::Create(ctx, "eq.slow", F, contBB);

        headBB->getTerminator()->eraseFromParent();
        IRBuilder<> hb(headBB);
        hb.CreateCondBr(hb.CreateICmpEQ(a, b, "eq.same"), contBB, testBB);

        IRBuilder<> tb(testBB);
        Value *aw = tb.CreatePtrToInt(a, i64Ty, "eq.aw");
        Value *bw = tb.CreatePtrToInt(b, i64Ty, "eq.bw");
        Value *any = tb.CreateICmpNE(
            tb.CreateAnd(tb.CreateOr(aw, bw), ConstantInt::get(i64Ty, constBit)),
            ConstantInt::get(i64Ty, 0), "eq.anyconst");
        tb.CreateCondBr(any, contBB, slowBB);          // no !prof in v1 — see Phase 6

        IRBuilder<> sb(slowBB);
        CallInst *r = sb.CreateCall(eqCallee, {a, b}, "eq.r");
        Value *tc   = sb.CreateIntToPtr(ConstantInt::get(i64Ty, trueWord), as1);
        Value *rb   = sb.CreateICmpEQ(r, tc, "eq.slowres");
        sb.CreateBr(contBB);

        IRBuilder<> pb(&*contBB->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(i1Ty, 3, "eq.res");
        phi->addIncoming(ConstantInt::getTrue(ctx),  headBB);
        phi->addIncoming(ConstantInt::getFalse(ctx), testBB);
        phi->addIncoming(rb, slowBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }
    if (!marker->use_empty())
        report_fatal_error("expandValueEqFastPath: surviving __eco_value_eq use");
    marker->eraseFromParent();
}
```

Note the PHI placement is legal by construction: `splitBasicBlock(ci, …)` makes `ci` the
FIRST instruction of `contBB`, so `contBB->getFirstInsertionPt()` is `ci` and the phi lands
ahead of it, at the top of the block, before `ci` is erased.

Call site in `runEcoBackend` — between the scratch-stack gc-leaf loop (:2511-2515) and
`expandInlineDerefs(m)` (:2517):
```cpp
    // eco.value.eq word-equality diamond. Before expandInlineDerefs (independent),
    // before applyCapacityHoisting (:2526-2542), before propagateGcFreeLeafAttrs
    // (:2565-2568), before module splitting, and before every RS4GC flavour.
    expandValueEqFastPath(m);
```

**2.5 — codegen fixture.** `test/codegen/value_eq_fastpath.mlir` (auto-discovered by
`CodegenIsolatedTest`'s `directory_iterator` over `test/codegen/*.mlir` — no registration),
three RUN lines exactly like `inline_alloc_tuple.mlir:1-3`:
```
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=MARK
// RUN: %ecoc %s -emit=llvm     2>&1 | %FileCheck %s --check-prefix=EXP
// RUN: %ecoc %s -emit=jit      2>&1 | %FileCheck %s --check-prefix=JIT
```
- `MARK:` **`llvm.call @__eco_value_eq`** — the `-emit=mlir-llvm` leg prints MLIR
  LLVM-dialect, not LLVM IR (`inline_alloc_tuple.mlir:53` is `// MARK: llvm.call
  @__eco_alloc_inline`; a `call i1 @…` pattern would never match). Plus
  `MARK-NOT: Elm_Kernel_Utils_equal`.
- `EXP:` `icmp eq ptr addrspace(1)`, `and i64`, `phi i1`; `EXP-NOT: @__eco_value_eq`;
  `EXP-NOT: memory(none)`; `EXP-NOT: speculatable`.
- `JIT:` behaviour, using only shapes a hand-written fixture can build (idioms lifted from
  `test/codegen/compare_case_rewrite_jit.mlir:146-165`): `eco.string_literal "apple" :
  !eco.value` × 2 equal + 1 unequal, `eco.constant Empty : !eco.value` (covers arm 2 and the
  `Nothing`/`[]`/`""` merged constant), and an `eco.construct.tuple2` pair for the boxed
  fallback. Print each i1 the way every shipped JIT fixture does — extend, box, `eco.dbg`:

  ```mlir
    %eq = eco.value.eq %sa, %sa2 : !eco.value
    %n  = arith.extui %eq : i1 to i64
    %bn = eco.box %n : i64 -> !eco.value
    eco.dbg %bn : !eco.value
    // JIT: 1
  ```

**Acceptance:** `TEST_FILTER=codegen cmake --build build --target full` green; the fixture's
three RUN lines pass; no other test changes behavior (nothing emits the op yet).

### Phase 3 — emission (compiler front end + the two synthesized sites)

**3.0 — the config flag.** `compiler/src/Compiler/Eco/Config.elm`: add
`valueEq : Bool` to `EcoConfig` (:34-48) with the one-line comment style of `aggPromote`
(:42), `valueEq = False` in `default` (:292-339), one `D.apply (D.optionalField "valueEq"
D.bool default.valueEq)` in `decoder` (:346-361), and in `hash` (:540+) append
`(if cfg.valueEq then [ "veq=1" ] else [])`.

> **Positional-decoder trap.** `decoder` is `D.pure EcoConfig |> D.apply …` (:348-361), so
> the `D.apply` order must match the field order in the type alias exactly. Append the field
> LAST in `EcoConfig` (after `sretTailFuncs`, :47), LAST in `default` (after
> `sretTailFuncs = True`, :338) and LAST in `decoder` (after :361). Any other placement
> silently shifts every field after it.

`compiler/src/Builder/Eco/Config.elm`: one more `Task.andThen` link reading `ECO_VALUE_EQ`,
appended after the current last link (`ECO_BORROW_OPT`, :260-264), plus
`applyValueEqOverride`, a verbatim copy of `applyAggPromoteOverride` (:267-291) with the
field swapped. The flag reaches codegen through `ctx.ecoConfig` (Context.elm:236, installed
by `withEcoConfig` :341-343), the same way `ctx.ecoConfig.ctorInline` is read at
Expr.elm:3460.

**3.1 — `utilsIntrinsic` arms.** `Intrinsics.elm:563-644`. New `Intrinsic` constructors
(:27-53):
```elm
    | ValueEq { negate : Bool }   -- eco.value.eq  (+ eco.bool.not when negate)
    | BoolEq  { negate : Bool }   -- eco.bool.xor  (+ eco.bool.not when NOT negate)
```
New arms, placed after the Char comparisons (:623) and before the compare-to-Order block
(:625):
```elm
        -- 3a. Bool equality never needed the kernel: both sides are already i1
        -- in SSA (REP_SSA), and the boxed round-trip was pure arm-1/arm-2
        -- traffic. eco.bool.xor exists and lowers to arith.xori
        -- (Ops.td:2605, EcoToLLVMArith.cpp BoolXorOpLowering).
        ( "equal", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BoolEq { negate = False })

        ( "notEqual", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BoolEq { negate = True })

        -- 3b. Everything whose ABI is already !eco.value. MVar / MFunction are
        -- deliberately EXCLUDED (whitelist discipline, NOT a divergence fix —
        -- arm 1 agrees with eqHelp on every shape, closures included, because
        -- `if (a == b) return true` precedes the tag switch, Utils.cpp:521-523):
        -- MVar _ CNumber may still resolve to an UNBOXED MInt/MFloat
        -- (Monomorphized.elm:211-219) so its SSA type is not knowably
        -- !eco.value here, and MFunction's ABI may be a PAP. Unlisted shapes
        -- keep today's kernel call.
        ( "equal", [ x, y ] ) ->
            if boxedComparable x && x == y then Just (ValueEq { negate = False }) else Nothing

        ( "notEqual", [ x, y ] ) ->
            if boxedComparable x && x == y then Just (ValueEq { negate = True }) else Nothing
```
with
```elm
{-| MonoTypes whose ABI representation is unconditionally `!eco.value`
(REP_ABI_001) and whose kernel equality has no closure/primitive hazard.
Whitelist discipline: anything not listed keeps today's boxed kernel call.
-}
boxedComparable : Mono.MonoType -> Bool
boxedComparable ty =
    case ty of
        Mono.MString -> True
        Mono.MUnit -> True
        Mono.MList _ _ -> True
        Mono.MTuple _ _ -> True
        Mono.MRecord _ _ -> True
        Mono.MCustom _ _ _ _ -> True
        _ -> False       -- MInt/MFloat/MChar handled above; MBool by 3a;
                         -- MVar/MFunction deliberately fall through
```
(Arities checked against `type MonoType`, Monomorphized.elm:227-239: `MList Int MonoType`,
`MTuple Int (List MonoType)`, `MRecord Int (Dict Name MonoType)`,
`MCustom Int IO.Canonical Name (List MonoType)`. The leading `Int` is a **structural hash**,
not an identity — the smart constructors at :419-423 derive it from the payload and
Monomorphized.elm:301 warns that a hand-written `MList 0 t` "carries a wrong hash and would
silently miss" — so `x == y` on two structurally identical types is `True` and the `x == y`
guard is a real same-type test, not an accidental always-False.)
Supporting arms: `intrinsicResultMlirType` (:71-150) `ValueEq _ -> I1` and `BoolEq _ -> I1`;
`intrinsicOperandTypes` (:155-253) `ValueEq _ -> [ Types.ecoValue, Types.ecoValue ]` (so
`unboxArgsForIntrinsic` no-ops, :294) and `BoolEq _ -> [ I1, I1 ]`; `generateIntrinsicOp`
(:773-981), modelled on the `IntComparison` arm (:835-841):
```elm
        ValueEq _ ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx "eco.value.eq" resultVar
                        ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) I1
                _ ->
                    Ops.ecoBinaryOp ctx "eco.value.eq" resultVar
                        ( "%error", Types.ecoValue ) ( "%error", Types.ecoValue ) I1

        BoolEq _ ->
            case argVars of
                [ lhs, rhs ] -> Ops.ecoBinaryOp ctx "eco.bool.xor" resultVar ( lhs, I1 ) ( rhs, I1 ) I1
                _            -> Ops.ecoBinaryOp ctx "eco.bool.xor" resultVar ( "%error", I1 ) ( "%error", I1 ) I1
```

**3.2 — the post-op + admissibility channels.** `generateIntrinsicOp` returns exactly ONE
`MlirOp` (`Ctx.Context -> Intrinsic -> String -> List String -> ( Ctx.Context, MlirOp )`,
:773) and both call sites splice it as `[ intrinsicOp ]`, so `notEqual` (and `BoolEq`'s
non-negated form) needs a post-op hook. Two new exported helpers in `Intrinsics.elm`
(mirroring `unboxArgsForIntrinsic`'s pre-op channel, :285-309). **Both must be added to the
module `exposing` list (:1) and the `@docs` line (:8)** — `intrinsicOperandTypes` is
deliberately unexported today, so exposure is not automatic:

```elm
{-| Ops emitted AFTER the intrinsic op, plus the var carrying the final result.
`notEqual` is emission-side negation — there is deliberately no second MLIR op
def for it. `eco.bool.not` lowers to `arith.xori %x, true` (Ops.td:2563-2575).
-}
intrinsicPostOps : Ctx.Context -> Intrinsic -> String -> ( List MlirOp, String, Ctx.Context )
intrinsicPostOps ctx intrinsic resVar =
    let
        needsNot =
            case intrinsic of
                ValueEq { negate } -> negate          -- eq  -> ne
                BoolEq  { negate } -> not negate      -- xor -> eq
                _ -> False
    in
    if needsNot then
        let ( v, c1 ) = Ctx.freshVar ctx
            ( c2, op ) = Ops.ecoUnaryOp c1 "eco.bool.not" v ( resVar, I1 ) I1
        in ( [ op ], v, c2 )
    else
        ( [], resVar, ctx )

{-| ONE gate applied after `kernelIntrinsic` matches, combining (a) the P3.0
config flag and (b) the ACTUAL SSA operand types that the MonoType-only lookup
cannot see. `eco.value.eq` requires both operands to already be `!eco.value`:
aggregate promotion / psplit (T1.3) can hand a tuple or single-ctor custom to a
call site as loose scalar slots, and the intrinsic path has no boxing step (it
only unboxes, :294) — it would emit an ill-typed op. `Nothing` routes the call
back to the untouched kernel-call branch.

`BoolEq` is deliberately NOT config-gated: it is unconditionally better than the
boxed kernel call and needs no flag. Every pre-existing intrinsic passes through
unchanged, so this helper is inert for them.
-}
admissibleIntrinsic : Bool -> List ( String, MlirType ) -> Intrinsic -> Maybe Intrinsic
admissibleIntrinsic valueEqEnabled argsWithTypes intrinsic =
    case intrinsic of
        ValueEq _ ->
            if valueEqEnabled && List.all (Tuple.second >> Types.isEcoValueType) argsWithTypes then
                Just intrinsic

            else
                Nothing

        _ ->
            Just intrinsic
```

Both argType-carrying `Expr.elm` sites change identically. At :3725 (`moduleName`) and
:4199 (`home`) replace
`case Intrinsics.kernelIntrinsic <home> name argTypes resultType of` with
```elm
                    case
                        Intrinsics.kernelIntrinsic <home> name argTypes resultType
                            |> Maybe.andThen
                                (Intrinsics.admissibleIntrinsic
                                    ctx1.ecoConfig.valueEq
                                    argsWithTypes
                                )
                    of
```
(`ctx1` and `argsWithTypes` are both already in scope at each site — `ctx1` is the ctx fed to
`unboxArgsForIntrinsic` at :3731 / :4204, and `argsWithTypes` is its second argument), and,
in the `Just intrinsic ->` body (:3729-3747 / :4201-4220), splice the post-ops after the
existing `( ctx3, intrinsicOp )` binding:
```elm
                                ( postOps, finalVar, ctx4 ) =
                                    Intrinsics.intrinsicPostOps ctx3 intrinsic resVar
                            in
                            { ops = argOps ++ unboxOps ++ [ intrinsicOp ] ++ postOps
                            , resultVar = finalVar
                            , resultType = Intrinsics.intrinsicResultMlirType intrinsic
                            , ctx = ctx4
                            , isTerminated = False
                            }
```
(`resultType` is unchanged: `eco.bool.not` is `I1 -> I1`, so the post-op never moves it.)

**The third `kernelIntrinsic` call site is Expr.elm:775** — `Intrinsics.kernelIntrinsic home
name [] monoType`. It passes `argTypes = []`, which cannot match `( "equal", [ x, y ] )` or
`( "equal", [ MBool, MBool ] )`, so the new arms are unreachable there. Leave it untouched;
do not thread the gate through it.

**3.3 — string-pattern `case` (Elm side).** `Patterns.elm:266-290`, `Test.IsStr`. Today the
arm binds `( eqVar, ctx4 ) = Ctx.freshVar ctx3` (:281-282), then
`( ctx5, cmpOp ) = Ops.ecoCallNamed ctx4 (Ctx.liveEcoValueVars ctx4) eqVar
"Elm_Kernel_Utils_equal" [ ( valVar, Types.ecoValue ), ( strVar, Types.ecoValue ) ]
Types.ecoValue` (:284-285), then `( unboxOps, resVar, ctx6 ) = Intrinsics.unboxToType ctx5
eqVar I1` (:287-288), and returns `( pathOps ++ [ strOp, cmpOp ] ++ unboxOps, resVar, ctx6 )`
(:290). Replace the whole `eqVar`-onwards block with a config-gated branch, keeping the
existing shape verbatim in the `else`:

```elm
                ( eqVar, ctx4 ) =
                    Ctx.freshVar ctx3

                ( eqOps, resVar, ctx6 ) =
                    if ctx1.ecoConfig.valueEq then
                        let
                            ( ctx5, veqOp ) =
                                Ops.ecoBinaryOp ctx4 "eco.value.eq" eqVar
                                    ( valVar, Types.ecoValue )
                                    ( strVar, Types.ecoValue )
                                    I1
                        in
                        ( [ veqOp ], eqVar, ctx5 )

                    else
                        let
                            ( ctx5, cmpOp ) =
                                Ops.ecoCallNamed ctx4 (Ctx.liveEcoValueVars ctx4) eqVar
                                    "Elm_Kernel_Utils_equal"
                                    [ ( valVar, Types.ecoValue ), ( strVar, Types.ecoValue ) ]
                                    Types.ecoValue

                            ( unboxOps, unboxedVar, ctx5b ) =
                                Intrinsics.unboxToType ctx5 eqVar I1
                        in
                        ( cmpOp :: unboxOps, unboxedVar, ctx5b )
            in
            ( pathOps ++ [ strOp ] ++ eqOps, resVar, ctx6 )
```

(`ctx1` is the ctx bound at :179 and carries `ecoConfig`; `Ops.ecoBinaryOp` has signature
`Ctx.Context -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> MlirType
-> ( Ctx.Context, MlirOp )`, Ops.elm:997.) On the flag-on path this also stops
`Ctx.registerKernelCall` — which `ecoCallNamed` invokes for any `Elm_Kernel_`-prefixed
callee, Ops.elm:663-668 — from emitting the `is_kernel` stub for `Elm_Kernel_Utils_equal` in
modules whose only use was string cases; relevant to P4.

**3.4 — string-pattern `case` (synthesized, SCF level).** BACKEND change ⇒ env-gated, not
Config-gated. `EcoControlFlowToSCF.cpp` (which has no `<cstdlib>` include or env helper
today — add both): a file-local static-lambda helper in the anonymous namespace, modelled on
`cmpCaseEnabled()` (EcoCompareCaseRewrite.cpp:74-80) but inverted to **default 0**:
```cpp
bool valueEqStrCaseEnabled() {                       // ECO_VALUE_EQ_STRCASE=1 opts in
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_STRCASE");
        return e && e[0] == '1' && e[1] == '\0';
    }();
    return on;
}
```
(`EcoToLLVMControlFlow.cpp` needs the identical predicate. It DOES include
`EcoToLLVMInternal.h` (:8) while `EcoControlFlowToSCF.cpp` does NOT — its includes are
:14-27, all MLIR + `../EcoDialect.h`/`EcoOps.h`/`Passes.h` — so there is no shared header
between them today. Simplest: two file-local copies with a cross-reference comment, exactly
as `getenv("ECO_CMPCASE")` is duplicated at EcoCompareCaseRewrite.cpp:76 and :83. Do NOT make
`EcoControlFlowToSCF.cpp` include `EcoToLLVMInternal.h` just for this — that header pulls in
the whole LLVM-lowering surface.) In
`CaseStringToScfIfChainPattern`, at BOTH `func::CallOp @Elm_Kernel_Utils_equal` + `UnboxOp ->
i1` pairs (:794-798 and :832-840), branch:
```cpp
        Value cond;
        if (valueEqStrCaseEnabled()) {
            cond = rewriter.create<eco::ValueEqOp>(
                loc, rewriter.getI1Type(), scrutinee, strLitOp);
        } else {
            auto callOp = rewriter.create<func::CallOp>(          // unchanged
                loc, "Elm_Kernel_Utils_equal", TypeRange{ecoValueTy},
                ValueRange{scrutinee, strLitOp});
            cond = rewriter.create<UnboxOp>(loc, rewriter.getI1Type(),
                                            callOp.getResult(0));
        }
```
`ensureEqualDeclared` (:762-774) and its call at :750 **stay** — they are what the
switch-off path needs — but guard the call with `if (!valueEqStrCaseEnabled())` so the
flag-on module does not gain a dead `func.func @Elm_Kernel_Utils_equal` stub, and update the
now-conditional comment at :1133.

**3.5 — string-pattern `case` (synthesized, LLVM level).**
`EcoToLLVMControlFlow.cpp::lowerStringCase`, same `ECO_VALUE_EQ_STRCASE` switch. Flag-on:
swap `runtime.getOrCreateUtilsEqual(rewriter)` (:411-412) for
`runtime.getOrCreateValueEqMarker(rewriter)` and replace the
`LLVM::CallOp` + `ConstantOp`/`IntToPtrOp`/`ICmpOp` decode block (:476-487) with a single
marker call whose i1 result IS `isEqual`. Flag-off: today's code verbatim. Same expansion
then covers these sites. (Note this path is reached only for `eco.case` ops that survive to
Stage 2; the SCF pattern at 3.4 handles the rest — that is why both must be switched
together.)

**3.6 — the behaviour golden.** New `test/elm/src/EqBoxedFastPathTest.elm`, same
auto-discovered `-- CHECK:` shape as `test/elm/src/BoolXorTest.elm` (see Phase 1). One
`Debug.log` line per admissible shape, each covering all three arms — a value compared with
ITSELF (arm 1), with a structurally-equal twin (arm 3 → True), and with a different value
(arm 2 or arm 3 → False) — plus the merged-empty constant, which is the only pure arm-2
witness reachable from Elm:

```elm
-- CHECK: strSame: True
-- CHECK: strEq: True
-- CHECK: strNe: False
-- CHECK: listEq: True
-- CHECK: listNe: False
-- CHECK: nilVsCons: False        -- Empty constant vs heap Cons: arm 2
-- CHECK: tupleEq: True
-- CHECK: recordNe: False
-- CHECK: customEq: True
-- CHECK: nothingVsJust: False    -- Empty constant vs heap Custom: arm 2
-- CHECK: boolEq: True            -- P3a: eco.bool.xor, not the kernel
-- CHECK: boolNe: True
-- CHECK: strCase: matched        -- exercises P3.3/P3.4/P3.5 (a `case s of "a" -> …`)
```

The `strCase` line must go through a literal string `case` expression so the three
string-pattern lowerings are covered by the same golden. Green under BOTH flag states — the
whole point is that the op is observationally identical to the kernel call.

**Acceptance:**
- **flag-off inertness (no carve-outs):** with `ECO_VALUE_EQ=0`, `ECO_VALUE_EQ_STRCASE=0`, a
  full build produces MLIR byte-identical to the pre-change tree — diff the Stage-2 `.mlir`
  dumps for two representative packages, and separately `cmp` the Stage-7a `-out.mlir`
  against a pre-change run.
- flag-on: `ECO_VALUE_EQ=1 ECO_VALUE_EQ_STRCASE=1 cmake --build build --target full` green.
- `EqDepthCutoffTest` and `EqBoxedFastPathTest` green under both flag states.

### Phase 4 — the gc-leaf fallback (HARD-gated on kernel-opt-07 Phase 5)

**Precondition A (owned by kernel-opt-07):** the `fprintf(stderr, "[eq] tag mismatch…")`
behind the non-atomic `static int traceCount` on the tag-mismatch path — **Utils.cpp:557-562**
(design doc said :550-556) — must be deleted first. It is an observable side effect *and* a
data race inside the function every equality funnels through.

**What it actually blocks, precisely** (the outline conflated two things): the trace is
*not* a GC hazard — kernel-opt-08's own trap list says so verbatim ("a side effect but not a
GC hazard"), and `gcLeafEligible` is derived only from `gcAlloc == GcNone && not
callsBackIntoElm`, neither of which the fprintf touches. What the trace blocks is the
**`Pure` trait on `eco.value.eq`** (Phase 2.1): `Pure` = `NoMemoryEffect +
AlwaysSpeculatable`, so MLIR may CSE, drop or speculate the op, and each of those changes
how many trace lines a program prints. So Precondition A gates **Phase 2** (landing the op
as `Pure`) as hard as it gates Phase 4. `ECO_VALUE_EQ_GCLEAF` stays `0` until 07 lands
anyway — one blocker, one moment, no partial state.

**Anchor drift corrected — there is NOT one declaration site.** The guidance's premise that
`EcoToLLVMRuntime.cpp:910-913` is the single, deliberately-not-gc-leaf declaration does not
hold in the current tree, and the "NOT gc-leaf … CGEN_072" comment it refers to actually
lives on `getOrCreateUtilsCmp3` (**:952-958**), not on `getOrCreateUtilsEqual` (whose only
comment is the one-line signature at :911). `Elm_Kernel_Utils_equal` is declared by **three**
paths today:

1. `EcoRuntime::getOrCreateUtilsEqual` (:910-914), pre-materialized at :1262;
2. `KernelFuncOpLowering` (EcoToLLVMFunc.cpp:26-97) converting the front end's `is_kernel`
   `func.func` stub (emitted by `generateKernelDecl`, Functions.elm:1959-2014);
3. `EcoControlFlowToSCF::ensureEqualDeclared` (:762-774), deleted by P3.4.

Path 2 runs in **Stage 0**, path 1 in the pre-materialization phase **after** it
(EcoToLLVM.cpp:307-312 → `symCache.clear()` :322 → `materializeAllRuntimeDecls` :343). Since
`getOrCreateFunc` returns early on a `lookupSymbol` hit (:133-134) *before* it applies the
`passthrough=["gc-leaf-function"]` attr (:143-149), **flipping the `gcLeaf` argument alone is
a silent no-op whenever any Elm module calls `==` on a boxed value** — i.e. essentially
always. Therefore:

- **4.1** Flip `getOrCreateUtilsEqual` (:913) to `/*gcLeaf=*/true` *and* replace its comment
  with the "NOT gc-leaf" rationale's inverse: `// gc-leaf: every eq path is
  GC-allocation-free (Utils.cpp:521-740; dictEq's scratch is a C++ std::vector at :776;
  StringOps::equal StringOps.hpp:1486-1533; ListCursor documented non-allocating at
  HeapHelpers.hpp:812-821). Coordinated with kernel-opt-07/08. gc-leaf ONLY — never
  memory(none)/speculatable (:884-891).` This covers path 1.
- **4.2** The module-level stamp in `expandValueEqFastPath` (§2.4) covers **all three**
  paths, exactly as `expandInlineDerefs` stamps `eco_follow_forward`
  (EcoBackend.cpp:886-887) and `runEcoBackend` stamps the scratch helpers (:2511-2515) — it
  sees the linked module after every decl channel has run, so it cannot miss one. This is
  the load-bearing one; 4.1 exists so the two channels cannot disagree.
  **The stamp MUST sit above `expandValueEqFastPath`'s `if (!marker) return;`** (see the
  §2.4 sketch): a module can call `Elm_Kernel_Utils_equal` with no `eco.value.eq` in it at
  all (flag-off, or call sites `admissibleIntrinsic` rejected), and those modules are
  precisely the ones the "covers all paths" claim is about. Behind the early return, the
  stamp would cover only marker-bearing modules and the claim would be false.
- **4.3** When kernel-opt-08 lands `eco.gc_leaf` on the `is_kernel` stub
  (Functions.elm:1995-2008 attr dict → `KernelFuncOpLowering`, EcoToLLVMFunc.cpp:26-97, plus
  its `gcLeafKernels` consult inside `getOrCreateFunc`), 4.2 becomes redundant and is
  deleted so `Elm_Kernel_Utils_equal` is stamped through exactly ONE channel. Mark 4.2
  transitional in its code comment. **Deletion criterion, not a date:** delete 4.2 only once
  (a) 08's Phase 5 has flipped `Config.kernelGcLeaf` default-on, AND (b) the grep gate below
  still shows the stamp in a module whose ONLY use of `equal` is a synthesized string case —
  such a module has no `is_kernel` stub to carry `eco.gc_leaf` (P3.3 removes the
  `registerKernelCall` that used to create one), so 08's stub channel does not reach it. If
  (b) fails, KEEP 4.2 and record why. There is NO `eco.kernel_cannot_gc` attr anywhere in
  this plan; the ONE decl attr is `eco.gc_leaf`, and kernel-opt-09's per-`eco.call`
  `eco.callee_gc_leaf` is a different, call-local channel this plan does not touch.
- **4.4** `eco.value.eq` needs **no** EcoGCPrepare change, gc-leaf or not: `isGroupBarrier`
  (:110-121) and `isCallSafepoint` (:125-140) key on `eco.call`/`func.call`/PAP ops only, and
  any non-allocation op unconditionally flushes the pending group (:240-245), so the op
  breaks grouping the same way the `eco.call` it replaces did. The shipped precedent is
  `eco.string.cmp3` → non-gc-leaf `Elm_Kernel_Utils_cmp3` (:952-958) with no EcoGCPrepare
  entry. This plan also consumes **nothing** from kernel-opt-09: `eco.callee_gc_leaf` is a
  per-`eco.call` attribute and `eco.value.eq` is not a call.

**Acceptance:** `EXP-NOT: memory(none)` / `EXP-NOT: speculatable` in the fixture; the
declaration carries `"gc-leaf-function"` exactly once —

```bash
%ecoc test/codegen/value_eq_fastpath.mlir -emit=llvm 2>&1 \
  | grep -n 'declare.*@Elm_Kernel_Utils_equal\|attributes #' | head -20
```

— i.e. one `declare` line and one attribute group carrying `"gc-leaf-function"`, and no
`memory(` / `speculatable` on it; the CGEN_072 assert (a stamped function still holding a
statepoint is a hard build failure) does not fire; heap-validate suite green.

### Phase 5 — residual boxed compare/lt/gt/ge (do LAST, only if warranted)

Same treatment, **CALL-ONLY** — no inline arm beyond word-equal → EQ — for the residue of
`Utils_compare` (296 sites), `lt` (80), `gt` (41), `ge` (3). The Aug 10 cmp series already
retired most of this machinery; **execute this phase only if kernel-opt-06's residue analysis
reports >200 surviving boxed sites AND the Stage-7a dynamic row for `Utils_lt` (30,447,459)
is still live after 06 lands.** Otherwise record "not warranted, residue N sites" here and
close. Note `Utils_lt/le/gt/ge` route through `cmp` (Utils.cpp:809-811 …), which is
allocation-free by the same audit, so the gc-leaf half is a two-line change to their
`getOrCreate*` decls if it is ever wanted independently.

### Phase 6 — default-on flips, invariant row, post-land tuning

1. **`ECO_VALUE_EQ_STRCASE` → `1`** (one line in each of the two helpers), once the full
   gate battery below is green in the flag-on configuration. Criterion: E2E green, the
   codegen fixture green, bootstrap converging to a new fixed point, and the flag-on/flag-off
   wall A/B showing no regression outside the ±2.8% noise band recorded in
   `benchmarks/kernel-opt.md`.
2. **`Config.default.valueEq` → `True`** on the same criteria, one line, separately
   revertable (this is the CGEN_072(e)/CGEN_074 "DEFAULT-ON since <date>, env `=0` is the
   escape hatch" precedent).
3. **Branch weights** on the arm-2 → arm-3 edge (`MDBuilder::createBranchWeights`, the
   `expandInlineDerefs` precedent at EcoBackend.cpp:889-893) using the Phase-0 census split.
   Measured only: land it as its own A/B leg, not bundled with 1 or 2.
4. **`design_docs/invariants.csv` row `CGEN_076`** (CGEN_075 is the current maximum, so 076
   is free) describing the op, the marker, the expansion choke point, and the "arms must
   remain bit-identical to `equalRespectingConstants` (UtilsExports.cpp:101-103)" contract.
   The CSV is `;`-separated with 6 columns — check the field count after editing; an
   unescaped `;` in the description silently splits the row.

## Traps & risks

1. **The single-declaration premise is false** (see P4). Flipping `getOrCreateUtilsEqual`'s
   `gcLeaf` alone is a no-op because the front end's `is_kernel` stub already occupies the
   symbol by the time pre-materialization runs. Stamp in `expandValueEqFastPath` too.
2. **REP_LLVM_002 miscompile class:** do NOT stamp `memory(none)` / `speculatable` on the
   fallback declaration or on the marker — motion-enabling attributes pre-RS4GC can move
   calls across statepoints (hazard documented at EcoToLLVMRuntime.cpp:884-891). gc-leaf
   alone is the contract, and the fixture carries `EXP-NOT:` lines for both.
3. **fprintf side effect (Utils.cpp:557-562):** blocks the **`Pure` trait** (CSE/DCE/
   speculation of the op changes how many trace lines print) until kernel-opt-07 deletes it —
   so it gates Phase 2, not just Phase 4. It is NOT a gc-leaf hazard (kernel-opt-08 Traps:
   "a side effect but not a GC hazard"); `ECO_VALUE_EQ_GCLEAF=0` is default-off for the
   lying-declaration risk and for 08 coordination, not because of this.
4. **depth-100 lie (Utils.cpp:566-569):** pin it with `EqDepthCutoffTest` BEFORE the op
   lands, and re-run it unchanged after. Landing an op on top of an unstated cutoff is how
   goldens rot.
5. **Closures — the outline had this BACKWARDS; do not re-introduce the claim.** `eqHelp`'s
   `if (a == b) return true;` (Utils.cpp:521-523) runs above the tag switch, so two
   pointer-equal closures already compare `true` today and the `Tag_Closure -> false` arm
   (:733-735) only ever sees two *distinct* closure pointers. **Arm 1 never disagrees with
   the kernel on any shape.** `MFunction`/`MVar` stay out of `boxedComparable` for whitelist
   discipline (Elm forbids comparing functions; `MVar _ CNumber` may still be unboxed), not
   to paper over a divergence.
6. **Faithfulness of arm 2 is *bit-exact*, including a latent quirk.** `isConstantBits` tests
   only bit 2 (Heap.hpp:323) whereas `Export::toPtr` additionally requires
   `ptr==0 && enum_idx==0 && padding==0` (ExportHelpers.hpp:54-56). A rodata literal pointer
   with bit 2 set would already be misclassified by today's `equalRespectingConstants`. Arm 2
   replicates `isConstantBits` exactly, so the op inherits — and does not widen — that
   behavior. Do NOT "fix" it inside this plan.
7. **`__eco_value_eq` must be pre-materialized.** Omitting the
   `materializeAllRuntimeDecls` line trips `getOrCreateFunc`'s frozen assert
   (EcoToLLVMRuntime.cpp:135-137) as parallel-Stage-2 UB, not a clean error.
8. **Aggregate promotion / psplit operands.** T1.3 can hand a tuple or single-ctor custom to
   a call site as loose scalars. The intrinsic path only *unboxes* (Intrinsics.elm:294) and
   would emit an ill-typed op. `admissibleIntrinsic`'s `Types.isEcoValueType` check
   (Intrinsics.elm:294 uses the same predicate) is the guard; keep it.
9. **Synthesized call sites:** the string-pattern case lowering emits its own `equal` calls
   in TWO places (EcoToLLVMControlFlow.cpp:411-412/:476-487 at LLVM level;
   EcoControlFlowToSCF.cpp:794-798/:832-840 at SCF level) — miss these and the
   census-vs-binary mismatch persists. They are BACKEND code, so they get their own env
   switch (`ECO_VALUE_EQ_STRCASE`); putting them behind the front end's `Config.valueEq` is
   impossible and leaving them unconditional would break the flag-off inertness gate.
10. **Deferred v2 (census-gated):** both-`Tag_Int` inline payload compare needs a HEAP_030
    forward-checked inline header load; payoff dubious since `Int == Int` at typed sites is
    already `eco.int.eq`. Do not build in v1.
11. **`ECO_KERNEL_GCLEAF_PILOT` does not exist in the tree** — `grep -rn KERNEL_GCLEAF_PILOT
    /work` hits only markdown (design_docs/kernel-boundary-reduction.md:2024,
    plans/kernel-call-census.md:138, and two plans quoting them); the pilot was
    measurement-only and reverted. kernel-opt-08 v2 already says so ("There is **no**
    `ECO_KERNEL_GCLEAF_PILOT` to retire", :62) — the stale claim lives in the **design doc**,
    not in 08. Do not plan around it.
12. **The gc-leaf stamp must not hide behind the marker early-return** in
    `expandValueEqFastPath` — see P4.2. Flag-off / non-admissible modules have no marker but
    still call `Elm_Kernel_Utils_equal`.
13. **`kValueEqSym` is not a thing.** `kSlotToHPtrSym`/`kHPtrToSlotSym` live in
    `Passes/EcoSlotCastBarriers.h:31-32` (namespace `eco`), and `EcoBackend.cpp` never
    includes `EcoToLLVMInternal.h`. Use the plain literal `"__eco_value_eq"` on both sides,
    as `__eco_resolve_fwd` and `__eco_alloc_inline` do.

## Dependencies

- **kernel-opt-07 (KernelFacts table): HARD blocker for Phases 2 AND 4** — it owns the
  fprintf/traceCount deletion (Precondition A), which is what makes the op's `Pure` trait
  honest (Phase 2.1) as well as what this plan waits on before flipping
  `ECO_VALUE_EQ_GCLEAF`; and it supplies the `(Utils, equal)` row whose `gcAlloc = GcNone`,
  `callsBackIntoElm = False` ⇒ `gcLeafEligible` justifies the stamp. Note 07's row keeps
  `callTimeEffect = EffObservableIO` / `cseSafe = False` until that same deletion, so
  "07 Phase 5 has landed" is the single observable precondition for both.
  Phases 0, 1 and 3a can proceed in parallel with `ECO_VALUE_EQ_GCLEAF=0`.
- **kernel-opt-08 (gc-leaf stamp):** shares the declaration mechanics. Coordination point is
  P4.3 — when 08's `eco.gc_leaf` attr on the `is_kernel` stub lands, this plan's transitional
  `expandValueEqFastPath` stamp is deleted so `Elm_Kernel_Utils_equal` is stamped once.
- **kernel-opt-06 (string ordering cmp3):** gates whether Phase 5 happens at all.
- **kernel-opt-09:** no dependency in either direction — `eco.value.eq` is not an `eco.call`,
  so `eco.callee_gc_leaf` never applies to it.
- **kernel-opt-10/12/13:** downstream beneficiaries — a `Pure` `eco.value.eq` is CSE-able
  where an `eco.call` never was.
- No dependency on 01/02/04/05/11/14 — mutually independent.

## Expected impact

Honest expectation, prior-calibrated: the gc-leaf pilot covering 64.1% of dynamic kernel
calls measured wall-FLAT, and four consecutive statepoint/metadata-only removals were flat —
so the FALLBACK arm alone buys nothing measurable. The wall case rests entirely on arms 1-2
DELETING the call + argument marshalling + statepoint on word-decidable hits, which is real
per-op work; its share of the 282.8M calls is **unmeasured until Phase 0**, and Phase 0's
25%-of-`nonbool_total` criterion is what decides whether the arms get built.

Independently of the census, three things are certain:
- **P3a is a pure deletion.** Bool `==`/`/=` today boxes two i1s to `0x4`/`0x5` and makes a
  kernel call (no `MBool` arm exists in `utilsIntrinsic`). After P3a it is one `arith.xori`.
  Every such site loses a call, a statepoint, and a group barrier.
- **Every retargeted site loses an `eco.call` group barrier and safepoint** (EcoGCPrepare
  :110-140), which is deleted work, not deleted metadata.
- **Two kernel defects die:** the `traceCount` data race (via 07) and the documented-and-
  tested depth cutoff.

If Phase 0 shows fallback-dominated traffic, the honest expectation is a flat wall; the item
then buys the above plus fewer statepoints / smaller stackmaps (the pilot's −637 KB of
`.llvm_stackmaps` is the calibration) and a CSE-able op for kernel-opt-10/13. Effort S once
07 has landed; M if the arms are built.

*(Phase 0 result — fill in on execution: `total=__ bool=__ nonbool_total=__ word=__ (__%)
const=__ (__%) slow=__ (__%)`, percentages over `nonbool_total`, archived at
design_docs/kernel-boundary/value-eq-arm-census-stage7a.txt.)*

## Gates

Run the suite ONCE, tee to a file, then grep the file — never re-run to re-read.

```bash
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
grep -E 'FAIL|Failed|failures|Falsifiable' /tmp/test_output.txt | head -40
tail -20 /tmp/test_output.txt
```

- **Full E2E:** `cmake --build build --target full` (never `check` — stale `.mlir`). Run it
  once fully flag-off and once with `ECO_VALUE_EQ=1 ECO_VALUE_EQ_STRCASE=1`.
- **Heap-validate suite:** configure a SEPARATE build dir so the flag does not leak into the
  benchmark/gate builds (`ECO_HEAP_VALIDATE` is a global `add_compile_definitions`,
  CMakeLists.txt:84-89):
  ```bash
  cmake --preset build -B build-val -DECO_HEAP_VALIDATE=ON
  cmake --build build-val --target full 2>&1 | tee /tmp/validate_output.txt
  ```
  expect the full 1632/1632 count with no walker aborts.
- **Self-host bootstrap byte-identity at the fixed point** — Stage 8c compares
  `eco-compiler-boot.mlir` against `eco-compiler-boot-2.mlir`
  (compiler/CMakeLists.txt:547-584):
  ```bash
  cmake --build build --target bootstrap 2>&1 | tee /tmp/bootstrap.txt
  grep -nE 'Stage 8c|fixed-point|differ' /tmp/bootstrap.txt
  ```
  Flag-OFF must be byte-identical to today's fixed point (this IS the inertness gate).
  Flag-ON legitimately changes output (a new op replaces a call), so ON must converge to a
  **NEW fixed point** — record both hashes, and inspect the diff against the old fixed point
  to confirm it consists only of `eco.value.eq` / `eco.bool.xor` lines replacing
  `eco.call @Elm_Kernel_Utils_equal` + `eco.unbox`.
- **Wall A/B with major-GC counts recorded** (GC-trigger lottery): 2×2 interleaved cold
  Stage 7a per `benchmarks/kernel-opt.md:96-130`, three arms —
  `ECO_VALUE_EQ=1 ECO_VALUE_EQ_STRCASE=1 ECO_VALUE_EQ_INLINE=1` vs the same with
  `ECO_VALUE_EQ_INLINE=0` (isolates the arms from the op) vs everything `=0` (isolates the
  whole feature). Log minor/major GC counts with every wall. The `-out.mlir` files are
  byte-identical only within the first two arms (both emit the op); against the all-off arm
  the output legitimately differs, so compare walls only within a pair lowered from the same
  Stage-5 `.mlir`.
- **Item-specific:**
  - Phase-0 arm-hit census archived under `design_docs/kernel-boundary/`, percentages
    recorded above, instrumentation reverted.
  - `test/elm/src/EqDepthCutoffTest.elm` green and UNCHANGED across P2/P3/P4.
  - `test/elm/src/EqBoxedFastPathTest.elm` green in BOTH flag states (§3.6).
  - `test/codegen/value_eq_fastpath.mlir` green on all three RUN lines.
  - **Front-end compile:** `cmake --build build --target elm-tests 2>&1 | tee
    /tmp/elm_tests.txt` — the Config/Intrinsics/Expr/Patterns edits compile and no existing
    intrinsic changed behaviour (`admissibleIntrinsic` returns `Just` for every pre-existing
    constructor).
  - Attribute grep gate:
    `%ecoc test/codegen/value_eq_fastpath.mlir -emit=llvm | grep -E 'memory\(none\)|speculatable'`
    must print nothing for `Elm_Kernel_Utils_equal` / `__eco_value_eq`.
  - Marker-erasure gate: `-emit=llvm` output contains no `__eco_value_eq`
    (`expandValueEqFastPath`'s `report_fatal_error` enforces it at build time too).
  - Post-land dynamic census (re-instrument, run, revert) showing the `Utils_equal` row
    reduced to fallback-only counts — arm-1/arm-2 hits no longer cross the boundary.

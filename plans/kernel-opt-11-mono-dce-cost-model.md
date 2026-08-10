# Kernel-Opt 11: Mono DCE via KernelFacts + kernel cost classes

**Status: IMPLEMENTATION-READY v2 — 2026-08-10.** (deepened from OUTLINE v1; anchors
re-verified against the tree). Derived from `design_docs/kernel-boundary-reduction.md`
§9 H4 (:2167-2174) + §8 inventory row 5 (:2007), the static callsite census
(`design_docs/kernel-boundary/callsite-census-self-compile.txt`, 17,005 sites / 130 symbols),
and the Stage-7a dynamic census (`kernel-census-dynamic-stage7a.txt`, 3.68B calls / 98 symbols).

## Files touched

| File | Change |
|---|---|
| `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` (owned by kernel-opt-07) | ADD derived `CostClass`/`costClass` (computed, never stored — no new record field, contract intact) **and add `CostClass(..), costClass` to the module's `exposing` list** (07 Phase 1 exposing block; without this the consumer does not compile) |
| `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` | imports (+2: `KernelFacts`, `Generate.MLIR.Intrinsics` — the latter drops to +1 if Step 3.2's layering fallback is taken); `RewriteCtx` +1 field; `isPureExpr` → `isPureExprGen : Bool -> …` + new kernel-call arm; dead-let gate :4780 flag-switches predicate; `computeCost` takes `InlineConfig` + new kernel-call arm; `kernelCallCost` (new); `Metrics`/`InternalMetrics` +1 counter (`kernelLetDCE`) + `bumpKernelDCE` |
| `compiler/src/Compiler/Eco/Config.elm` | `InlineConfig` +6 fields; `default.inline` +6; `inlineDecoder` +6; `hash` +2 tokens (`kfdce=1`, `kcc=i/g/a/h`) |
| `compiler/src/Builder/Eco/Config.elm` | 6 env overrides + doc block (`ECO_KERNEL_FACTS_DCE`, `ECO_KERNEL_COST_CLASSES`, `ECO_KERNEL_COST_{INLINE,GCLEAF,ALLOC,HOF}`) |
| `compiler/src/Builder/Generate.elm` | `renderInlineReportWith` prints `kernelLetDCE=` |
| `design_docs/debug-log-ordering-policy.md` | **NEW** — the shared Debug/⊥ policy (Phase 1), consumed by 11, 13, CafHoist, CafDedupe, fusion |
| `design_docs/invariants.csv` | **NEW row** `OPT_DEBUG_ORDER_001` pointing at the policy doc |
| `test/elm/src/DebugLogOrderingTest.elm` | **NEW** E2E invariant test pinning the policy (`-- CHECK-NEXT:` chain). **No registration step**: `ElmE2EBase::discoverTests` (`test/ElmE2ETestBase.hpp:1089-1106`) globs `test/elm/src/*.elm` at run time and admits any file with a top-level `main` (`hasTopLevelMain`, :1074-1087); the suite is built by `test/elm/ElmTest.hpp:8-10`. `TEST_FILTER` is a substring match on the test name (`ElmE2ETestEntry::collectTests`, :1123-1128). No CMake edit, no `cmake --preset` reconfigure |
| `plans/kernel-opt-11-mono-dce-cost-model.md` | this file — Phase-0 census table + per-constant A/B ledger recorded here |

**Nothing under `compiler/src` is a NEW `.elm` file**, so this plan needs **no**
`cmake --preset build` reconfigure (contrast kernel-opt-07/13, which add modules to the
configure-time `file(GLOB_RECURSE ELM_SOURCES …)`, compiler/CMakeLists.txt:126-129).

## Flag & rollback

Two **independent** flags, both `InlineConfig` fields, both **default `False`**, both
artifact-affecting (hash tokens appear only when on, so every existing config hashes
exactly as today and shares its caches). Precedent read for shape: `inline.arityRaise`
(`Config.elm:231` field, `:312` default, `:386` decoder, `:612-623` hash token,
`Builder/Eco/Config.elm:170-174` env chain link). Take the *placement* from `arityRaise`
but **not** its override function: `applyArityRaiseOverride` (:978-1001) is one-directional
(only `1|true|yes` sets True; `0` cannot force it off). Use `applyAggPromoteOverride`
(:272-290) as the override template — it accepts `1|true|yes|on` and `0|off` and ignores
anything else, which is what makes the kill switch real.
Env overrides run inside `applyEnvOverrides` (`Builder/Eco/Config.elm:112-264`), which the
module docstring states is deliberately applied *there* "so the override participates in
`Config.hash`" — that is what makes `ECO_KERNEL_FACTS_DCE=1` a distinct cache key rather
than a silent artifact mutation.

| Flag | JSON / env | Gates exactly | Hash token |
|---|---|---|---|
| `inline.kernelFactsDce` | `"kernelFactsDce"` / `ECO_KERNEL_FACTS_DCE=1\|0` | **The `isPureExpr` widening at ONE consumer only** — the dead-binding gate `MonoInlineSimplify.elm:4780`. Nothing else. | `kfdce=1` |
| `inline.kernelCostClasses` (+ the four Int knobs `kernelCostInline/GcLeaf/Alloc/Hof`) | `"kernelCostClasses"` etc. / `ECO_KERNEL_COST_CLASSES=1`, `ECO_KERNEL_COST_INLINE=<n>` … | **`computeCost`'s kernel-callee arm only.** Off ⇒ the arm is byte-identical arithmetic to today. | `kcc=<i>/<g>/<a>/<h>` (whole vector, so every A/B leg is a distinct cache key) |

**Decision pinned:** the cost-class change does **not** ride `kernelFactsDce`. They are
orthogonal transforms with opposite blast radii (DCE deletes work; cost classes move
inliner thresholds, historically high blast radius), and a shared flag would make the
mandatory per-constant A/B impossible to attribute.

**Why the constants are config knobs rather than source constants:** `Config.hash` keys
the Details cache (`Terminal/Make.elm:219`), and a compiler *source* constant change is
invisible to it — an A/B between two constant values would silently reuse `~/.eco`
package artifacts produced by the other value. Putting the vector in the hash makes each
leg cache-disjoint by construction. (Memory: *eco local-package stale stage cache*,
*harness cache env-blind*.)

**Rollback:** `ECO_KERNEL_FACTS_DCE=0` / `ECO_KERNEL_COST_CLASSES=0` (or simply leaving
them unset — both default `False`) restore today's behaviour exactly, with no recompile of
the compiler; artifacts regenerate under the pre-feature hash and hit the pre-feature
caches. Full revert = drop the **six** `Config.InlineConfig` fields with their decoder /
default / hash / env-override lines, and the two `MonoInlineSimplify` arms; the Phase-1
policy doc, the invariants row, the E2E test and the `kernelLetDCE` counter are keepers
regardless (they document behaviour that is already true).

## Goal

Two small, independent consumers of the kernel-opt-07 KernelFacts table:
(a) let `isPureExpr` say True for kernel calls the table certifies droppable, so the
dead-binding gate can delete a dead `let w = String.length s`; (b) replace `computeCost`'s
flat kernel-callee score with per-symbol cost classes derived from the table's axes.
Ends the row-5 contradiction: `isPureExpr` treats ALL kernel calls as impure while
`CafHoist`/`CafDedupe` treat all non-Debug kernel exprs as pure enough to hoist/merge.

## Evidence

All anchors below re-verified against the working tree on 2026-08-10.

- **(a) DCE blocked today.** `isPureExpr` (`MonoInlineSimplify.elm:5102`, docstring
  :5098-5101 "Function calls might have side effects (like Debug.log)"):
  `MonoVarKernel _ _ _ _ _ -> False` at **:5114-5116**, `MonoCall _ _ _ _ _ -> False` at
  **:5131-5133**. Sole consumer of interest: the dead-binding gate
  `else if laterUses == 0 && isPureExpr bound then … bumpLetElimination` at
  **:4780-4781**, inside `dropDeadDefs` (:4744-4796). Two further consumers exist —
  the partial-forward guards `List.all isPureExpr boundArgs` at **:3477** (global callee)
  and **:3499** (kernel callee, H6.1 F3). Net: no dead pure kernel call is removable at
  Mono level.
- **(b) cost distortion, both directions.** `computeCost` (**:1218-1277**) scores
  `MonoVarKernel` at **1** (:1230-1231) and `MonoCall` at `5 + computeCost func + sumBy
  computeCost args` (:1245-1246) — so *every* kernel call costs exactly **6 + args**,
  whether it lowers to one `eco.int.add` or to a rope-allocating `Utils_append`.
  Consumers of the number: `buildLoopifiables` (`computeCost body > budget`, **:1531**,
  where `budget = 2 * max threshold hofThreshold` = **50** at :1524-1525)
  and the inline-candidate admission test in `initRewriteCtx`
  (`cost = computeCost body` **:2150-2151**, compared against `inlineConfig.threshold` = 10
  and `hofBudget = max threshold hofThreshold` = 25 at **:2180-2189**). Design doc row 5,
  consequence column (:2007).
- **The contradiction being resolved** (row 5): `CafHoist.elm:392-393` — the leaf arm
  `Mono.MonoVarKernel _ _ home _ _ ->` (:392) `( { leafInfo | hasDebug = home == "Debug" }, [], ctx )`
  (:393) is the *entire* effect model (consumed at `CafHoist.elm:347`,
  `else if info.hasDebug then` → ineligible); `CafDedupe.oneRound` (`CafDedupe.elm:92-119`)
  buckets and merges structurally equal `MonoDefine` specs by `CafHoist.fingerprintOf` +
  `==` on the region-zeroed tree with no purity check at all. Both default-off
  (`Config.elm:321`).
- **`--optimize` does NOT strip `Debug` on the native path** (new finding, load-bearing
  for Phase 1). `checkForDebugUses` (`Builder/Generate.elm:259-266`) is reached only from
  `checkDebugAndGenerate` (:195-198) ← `prod` (:188-192), i.e. the **JS** backend
  (`Terminal/Make.elm:648-654`). The MLIR/native path enters at
  `writeMonoMlirStreaming` (:1147-1148) / `writeMonoMlirStreamingBytecode` (:1177-1178)
  → `buildMonoGraph` (:687) → `runInlineSimplifyPhase` (:807), with **no Debug check**
  anywhere (`Terminal/Make.elm:336/349/411/425`; the JS entries are :651/:654). `Debug.log`
  therefore survives to Mono and to codegen, where `Generate/MLIR/Expr.elm:3921` matches
  `( "Debug", "log", [ ( labelVar, _ ), ( valueVar, valueType ) ] )` and emits an **`eco.dbg`
  op** (not a kernel call). Lowering: `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp:24-121`
  → `eco_dbg_print_typed` (`runtime/src/allocator/RuntimeExports.cpp:3411-3426`), whose
  2-arg/string-label special case emits exactly `label: value\n` through `output_text` —
  i.e. into the **captured program output stream**, interleaved with ordinary output. That
  `label: value` shape is what the E2E `CHECK` fixtures assert.
  (`elm-kernel-cpp/src/core/DebugExports.cpp:26-42` defines the C export
  `Elm_Kernel_Debug_log` via `eco_output_text`; it is the *interpreter/kernel-call* form and
  is not what the MLIR path emits. `Elm::Kernel::log` in `core/Debug.cpp:28-50` — the
  `std::cout` one whose comment claims the omission — is **dead**: declared at `Debug.hpp:12`
  and called from nowhere in `elm-kernel-cpp/` or `runtime/` (grepped 2026-08-10).)
  The comment at `Debug.cpp:47-48` ("The compiler omits Debug.log calls in optimized
  builds") is therefore **false for this compiler, and its function is unreachable** —
  **all 558** fixtures in `test/elm/src/` (and 863 across every E2E corpus) print via
  `Debug.log`, e.g. `test/elm/src/StringEmptyTest.elm`. The entire E2E suite depends on
  `--optimize` NOT stripping Debug.
- **Sizing is free.** The count of dead pure kernel calls DCE would remove falls out of
  the cse-pure-calls C1 census (kernel-opt-13's first step) at zero extra cost — H4
  explicitly marks impact "unmeasured, census-able for free during C1" (row 5 impact col).

## Approach

### Phase 0 — free census (piggyback on kernel-opt-13 C1). Sizes (a) before any code lands.

Mechanism is **kernel-opt-13's**, not re-specced here: `ECO_CSE_REPORT=1`, output-only,
excluded from `Config.hash` (`plans/kernel-opt-13-mono-cse.md` Phase 0 §0.5 "kernel-opt-11
ride-along"; `plans/cse-pure-calls.md:139-141`). This plan adds **two counters** to that
report's existing `cse-dce:` line — the walk already visits every `MonoLet` with a
liveness test and a safe/droppable classification, so the extra work is two increments.

- **Insertion point:** kernel-opt-13 §0.5, inside `CseCensus.elm`'s walk, using **13's own
  local `countLocalUses : Name -> MonoExpr -> Int` helper**. Do **not** try to reuse
  `dropDeadDefs`'s liveness test: `usesInDefs` is a `let`-local inside `dropDeadDefs`
  (MonoInlineSimplify.elm:4747-4749) and `countUsages` (:5193-5194) is private — the module's
  `exposing` list is `(Metrics, optimize, buildBodyLookup, countClosures, residualTaxonomy,
  functionResultCensus)` (MonoInlineSimplify.elm:1) and neither is in it.
- **Counted** — 13 already specifies the first two; this plan requests the third and
  fourth, each one `case` arm on the same `bound` expression:
  1. `deadPureLets` (13) — dead binding, `CsePurity.isSafeCall bound`.
  2. `deadDroppableKernelLets` (13) — as above, callee is a `MonoVarKernel` and (post-07)
     `KernelFacts.droppable`.
  3. `deadBareKernelVar` (**this plan**) — dead binding whose `bound` is a **bare**
     `MonoVarKernel _ _ _ _ _`. Feeds decision D-K below.
  4. `deadLets` (**this plan**) — every dead `Mono.MonoDef` binding regardless of shape.
     This is D-K's denominator; without it the "< 0.5 % of dead bindings" criterion has no
     defined base.
- **`deadDroppableKernelLets` is an UPPER bound on what (a) will actually delete.** The
  census classifies on the callee only; the Phase-2 arm additionally requires every
  argument to be pure (`List.all (isPureExprGen kDrop) args`). The realized number is
  `kernelLetDCE` after Phase 2; the gap is argument impurity and is expected, not a bug.
- **Output format** — 13's existing two lines plus the two requested tokens, so 11 and 13
  grep the same run (13 Phase 0 §0.6):
  ```
  cse-dce: deadLets=<n> deadPureLets=<n> deadDroppableKernelLets=<n> deadBareKernelVar=<n>
  cse-dce top: String.length=6 Utils.compare=3 …
  ```
- **Commands** (13 Phase 0.8 (b) verbatim, retargeted; run from `/work`):
  ```bash
  cd /work
  BK=build/compiler/build-kernel
  rm -rf "$BK/eco-stuff"
  ( cd "$BK" && ECO_MONO_ENGINE=subst ECO_CSE_REPORT=1 \
      ./bin/eco-compiler make --optimize --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/census.mlir /work/compiler/src/Terminal/Main.elm ) \
    2>/tmp/kopt11-census.txt
  grep -E '^cse-(census|dce)' /tmp/kopt11-census.txt
  ```
  Plus the mandatory user workload — self-compile alone is product-and-corpus and a hot
  site in it is ambiguous. Use 13's Phase 0.8 (c) command verbatim (it is also the
  `annotateCallStaging` canary):
  ```bash
  ( cd /work/projects/elm-aws-codegen && ECO_CSE_REPORT=1 /usr/bin/time -v \
      /work/build/compiler/build-kernel/bin/eco-compiler make src/elm/Top.elm \
      --local-package eco/kernel=/work/eco-kernel-cpp --output=/tmp/aws-cse.mlir ) 2> /tmp/cse_aws.txt
  grep -E '^cse-(census|dce)|Elapsed \(wall' /tmp/cse_aws.txt
  ```
- **If kernel-opt-13 has NOT landed** (it is a SOFT dependency, and 13's own D-C gate may
  have closed it at Phase 1), do not re-implement a census module. Instead take the
  counters from the Metrics plumbing this plan is already adding in Step 2.3: add
  `deadLets` / `deadBareKernelVar` / `deadDroppableKernelLets` alongside `kernelLetDCE` at
  the same five registration points and read them off `ECO_INLINE_REPORT=1`.
  **Placement matters — do NOT bump inside `dropDeadDefs`'s `go`.** `dropDeadDefs`
  re-runs itself while anything dropped (:4792-4796), and a dead-but-kept binding (e.g. a
  bare `MonoVarKernel`, which today's `isPureExpr` refuses to drop) is re-visited on every
  iteration, so a counter there over-counts by the iteration depth. Instead run a
  **one-shot classifying fold over the spine immediately before the single
  `dropDeadDefs` call site** — `( keptSpine, ctx3 ) = dropDeadDefs ctx2 (List.reverse
  spineSimplifiedRev) finalBody1` at `:4736-4737` — as a sibling `let` binding taking the
  same `List.reverse spineSimplifiedRev` and `finalBody1`, reusing a copy of `go`'s
  liveness expression (`usesInDefs name rest + countUsages name finalBody`). Same numbers,
  no new module, counted exactly once. These counters are throwaway only if D-K says "keep
  False" — otherwise they stay as attribution counters.
- **Acceptance:** the `cse-dce:` line lands in this file's *Results* section regardless of
  value, for both corpora. **No branch of this plan is cancelled by a low count** — (a)
  still lands for the contradiction/enabling value — but the number sets the wall
  expectation in writing.

### Phase 1 — Debug.log ordering policy (owed FIRST; blocking). Zero code.

Retires the debt `plans/cse-pure-calls.md:67-80` records as *owed and never written*
(originally owed by `plans/opt-tier2-cons-fusion.md` U-T2.4′). **Written once, at
`design_docs/debug-log-ordering-policy.md`**; kernel-opt-13 references the same path.
No transform in this plan or in 13 lands before this file exists.

Draft body (this is the text to commit, not a summary of it):

> # Debug/⊥ observable-ordering policy for Elm-level optimizations
> **Scope.** Binds every pass that deletes, duplicates, merges, or moves an Elm-level
> expression: Mono DCE (kernel-opt-11), Mono CSE (kernel-opt-13), `CafHoist`, `CafDedupe`,
> bytes/cons fusion, and the inliner's beta/forward rewrites.
> **Fact the policy rests on.** On the **MLIR/native path `--optimize` does not remove
> `Debug.*`**: `checkForDebugUses` (`Builder/Generate.elm:259-266`) runs only under the
> JS `prod` entry (:188-198, reached from `Terminal/Make.elm:654`); the native path
> (`Terminal/Make.elm:336/349/411/425` → `Generate.buildMonoGraph:687`) never calls it.
> `Debug.log` lowers to an `eco.dbg` op (`Generate/MLIR/Expr.elm:3921`) →
> `eco_dbg_print_typed` (`runtime/src/allocator/RuntimeExports.cpp:3411-3426`), which
> writes `label: value\n` into the captured program output stream, interleaved with
> ordinary output. The `std::cout` comment at `elm-kernel-cpp/src/core/Debug.cpp:47-48`
> claims the opposite; its function has no callers and is dead.
> **D-1 (no deletion).** An expression that transitively contains a `Debug.*` kernel
> reference is never droppable, whatever the KernelFacts row says. `(Debug, log)` carries
> `callTimeEffect = EffObservableIO` ⇒ `cseSafe = False` ⇒ `droppable = False`, and the
> arg-purity recursion propagates it; the rule is nonetheless **normative** — a future
> pass must re-establish it, not inherit it by luck.
> **D-2 (no merge).** Two occurrences of an expression that transitively logs are never
> CSE-merged: the number of emitted lines is observable output. **The merge licence is
> refused, not deferred by accident** — kernel-opt-13 asked whether `--optimize` should
> license merging two evaluations of a pure-but-logging expression; the answer in v1 is
> NO. Granting it later is a deliberate amendment to THIS file, and the size of what it
> would unlock is already measured: kernel-opt-13's `debugExcluded` census counter.
> **D-3 (motion).** Relative order of two logging expressions is preserved. A logging
> expression may not be hoisted out of a conditional, nor into or out of a loop body
> (both change the line count). It may move within a straight-line region if it crosses
> no other logging or ⊥-capable expression. `CafHoist` already implements the strictest
> form (`hasDebug` ⇒ ineligible, `CafHoist.elm:392-393` set, `:347` consumed) and keeps it.
> **D-4 (⊥ selection).** Under `--optimize`, when two occurrences would both crash or
> diverge, an optimizer may keep either; the crash **message** may therefore change.
> E2E assertions on crash text must not depend on which occurrence produced it. This is
> the latitude kernel-opt-13 records for its C4 widening; C2/v1 does not use it, and
> kernel-opt-11's `droppable` (which requires `totality == Total`) cannot use it at all.
> **D-5 (no `--optimize` latitude).** No pass may assume `Debug` is absent because
> `--optimize` was passed. Acquiring that latitude requires first making the native path
> run `checkForDebugUses` — a separate, deliberate change with its own gates.
> **Pinned by** `test/elm/src/DebugLogOrderingTest.elm` — **D-1 and D-3** (non-deletion
> and order), run in both `ECO_KERNEL_FACTS_DCE` flavors — and by invariant
> `OPT_DEBUG_ORDER_001`. **D-2 is not pinnable until a merging pass exists**: nothing in
> the pipeline merges Elm-level expressions today, so its fixture is owed by kernel-opt-13
> C2 and must land with it. D-4/D-5 are normative statements with no fixture; D-5's
> falsifier is the day someone makes the native path call `checkForDebugUses`.

`invariants.csv` row. Format is the header at `design_docs/invariants.csv:1`
(`id;phase;category;status;description;source`); keep the description `;`-free; `source`
is a `|`-separated list. **Insertion point:** append as a new last line. The file is 639
lines with `CGEN_075` last (:639), so the row is line **640** — unless kernel-opt-07/08's
`KERNEL_FACTS_001` has already claimed 640, in which case append after it. `CrossPhase`
(36 existing rows), `ForbiddenAssumptions` (17) and `enforced` (233) are all existing
vocabulary values — no new field values are introduced. (`Compiler.GlobalOpt.MonoCse` is
deliberately **not** listed in `source`: it may never exist — 13's D-C gate can close 13 at
Phase 1. Whoever lands C2 appends it then.)

```
OPT_DEBUG_ORDER_001;CrossPhase;ForbiddenAssumptions;enforced;Debug/bottom observable-ordering policy - full text design_docs/debug-log-ordering-policy.md. Any Elm-level pass that deletes duplicates merges or moves an expression must treat an expression transitively containing a Debug.* kernel reference as non-droppable non-mergeable and order-fixed. --optimize does NOT strip Debug on the MLIR path - checkForDebugUses (Builder/Generate.elm:259-266) is reached only from checkDebugAndGenerate (:195-198) under the JS prod entry (:188-192) and the native path Terminal/Make.elm:336/349/411/425 never calls it - so no pass may assume Debug absence. Debug.log lowers to eco.dbg (Generate/MLIR/Expr.elm:3921) and prints label: value into the captured program output stream via eco_dbg_print_typed. Bottom-selection latitude under --optimize permits keeping either of two crashing occurrences and the crash message may change. Pinned by test/elm/src/DebugLogOrderingTest.elm;Compiler.GlobalOpt.MonoInlineSimplify|Compiler.GlobalOpt.CafHoist|Compiler.GlobalOpt.CafDedupe
```

E2E test sketch. Harness shape copied from `test/elm/src/StringEmptyTest.elm` **including
directive placement** (its `-- CHECK:` block sits between the module docstring and the
imports, and every one of the 558 fixtures follows that shape). The `-- CHECK-NEXT:` chain
pins presence *and* order *and* absence of duplicates in one directive stream
(`test/CheckPatterns.hpp:19-22`: "must match on the line immediately after the line the
previous constraint matched on; each further CHECK-NEXT advances one more line"). Expected
line shape `label: value` comes from `eco_dbg_print_typed`'s 2-arg/string-label special
case (`RuntimeExports.cpp:3413-3419`); strings print quoted (`StringEmptyTest` asserts
`empty: ""`).

```elm
module DebugLogOrderingTest exposing (main)

{-| Pins design_docs/debug-log-ordering-policy.md D-1/D-2/D-3 under BOTH
ECO_KERNEL_FACTS_DCE flavors. `deadLogged` is a DEAD binding whose bound
expression is a droppable kernel call (String.length) applied to a LOGGING
argument: D-1 forbids dropping it (the arg-purity recursion in isPureExprGen
sees (Debug, log) -> droppable = False). `deadPure` is the positive control —
dead, droppable, no Debug: flag-on it disappears, which is unobservable here
by design; the observable is the kernelLetDCE counter under
ECO_INLINE_REPORT=1, asserted in Phase 2, not here.
-}

-- CHECK: a: "start"
-- CHECK-NEXT: b: "hello"
-- CHECK-NEXT: c: "mid"
-- CHECK-NEXT: d: "abcd"
-- CHECK-NEXT: e: 4

import Html exposing (text)


main =
    let
        _ = Debug.log "a" "start"
        deadLogged = String.length (Debug.log "b" "hello")
        deadPure = String.length "xyz"
        _ = Debug.log "c" "mid"
        kept = String.length (Debug.log "d" "abcd")
        _ = Debug.log "e" kept
    in
    text "done"
```

**Test the test before trusting it (mandatory, one build).** `CHECK-NEXT` is parsed by
`CheckPatterns.hpp` and used today only by three `test/codegen/*.mlir` fixtures —
**zero** of the 558 `test/elm/src/*.elm` fixtures use it, so this is its first Elm-host
consumer. Before recording the test as a gate, break it once on purpose (swap the `c:` and
`d:` directives) and confirm the suite goes RED; restore. If the directive does not fire
in the Elm host (e.g. the captured stream carries harness lines between program lines),
**fall back** to: distinct payloads per log (`"L1".."L5"`) + plain `-- CHECK:` for each,
which still pins presence and D-1 non-deletion but loses the order and duplicate pins;
record the downgrade in this file and move D-3's pin to a `test/codegen/*.mlir`
`CHECK-NEXT` fixture instead.

**Acceptance (Phase 1):** policy file + invariants row + test committed; test green at
today's behaviour (the flag does not exist yet — the flag-on leg of this test is a **Phase
2** acceptance item, listed there). Note the harness-cache trap for the later flag-on run:
touch the corpus first (`touch /work/test/elm/src/*.elm`) — the flag *is* in `Config.hash`
(`kfdce=1`) so the Details cache is keyed correctly, but the test harness's own staleness
check is mtime-based.

### Phase 2 — (a) `isPureExpr` consults KernelFacts, at ONE call site.

**Import & cycle check.** `MonoInlineSimplify`'s import list is
`MonoInlineSimplify.elm:23-33` (Array, `Compiler.AST.Monomorphized as Mono`,
`Data.BitSet`, `Data.Name`, `Eco.Config as Config`, `Graph`, `Monomorphize.Closure`,
`Monomorphize.MonoTraverse`, `Reporting.Annotation`, `Dict`, `System.TypeCheck.IO`) —
it does **not** import anything from `GlobalOpt.Borrow` today. Add:

```elm
import Compiler.GlobalOpt.KernelFacts as KernelFacts
```

Acyclic: `KernelFacts` (the 07 extension of `Borrow/KernelSigs.elm`, whose whole import
list today is `Compiler.Data.Name` + `Dict`, `KernelSigs.elm:31-32`) imports nothing from
`GlobalOpt` or `Generate`. `MonoInlineSimplify` itself is imported only by
`Builder/Generate.elm:77` and `Generate/MLIR/Backend.elm:27`, neither reachable from
`KernelFacts`.

**Why 11 reads `KernelFacts` directly and not kernel-opt-13's `CsePurity`** (13's
dependency note says 11 "will consume `CsePurity`" — this plan does not, deliberately, and
that is the reconciliation): (i) `CsePurity.provisionalCseSafe` is explicitly a bring-up
scaffold "deleted the day kernel-opt-07 lands" (13, Traps); (ii) `droppable` needs
`totality`, which `CsePurity` does not carry (13's own §0.5 says `deadDroppableKernelLets`
becomes `cseSafe && totality == Total` post-07); (iii) 11 is a **hard** dependent of 07 and
only a **soft** dependent of 13, so it must not acquire a build dependency on 13's modules
— 13's D-C gate may close 13 at Phase 1 without `MonoCse.elm` ever landing. If 13 has
landed, `CsePurity` and this arm answer identically for kernel callees post-07 by
construction; that agreement is worth one assertion in 13's census output, not a shared
call path.

**Step 2.1 — generalize the predicate.** Rename `isPureExpr` (`:5102-5162`),
`isPureExprDef` (`:5165-5172`) and `isPureDecider` (`:5175-5190`) to
`isPureExprGen : Bool -> MonoExpr -> Bool` / `isPureExprDefGen` / `isPureDeciderGen`,
threading the flag through every recursive arm exactly as the existing arms recurse.
`isPureExprDef`/`isPureDecider` have **no callers outside this trio** (grepped: :5144 and
:5150 only), so they need no alias; `isPureExpr` does (`:3477`, `:3499`, `:4780`) and keeps
one, so **:3477 and :3499 stay byte-unchanged**:

```elm
{-| Legacy predicate: every call is impure. Kept verbatim for the H2.5/H6.1
partial-forward guards (:3477, :3499), which relocate their args and are NOT
part of the kernelFactsDce widening.
-}
isPureExpr : MonoExpr -> Bool
isPureExpr =
    isPureExprGen False


{-| Dead-binding predicate: additionally drops kernel calls the audited
KernelFacts table certifies `droppable` (cseSafe AND totality == Total).
-}
isDroppableExpr : MonoExpr -> Bool
isDroppableExpr =
    isPureExprGen True


isPureExprGen : Bool -> MonoExpr -> Bool
isPureExprGen kDrop expr =
    case expr of
        -- … the True/False leaf arms :5105-5123 and :5127-5129 are unchanged;
        -- every recursive arm (:5124-5125 MonoList, :5139-5141 MonoIf,
        -- :5143-5144 MonoLet, :5146-5147 MonoDestruct, :5149-5150 MonoCase,
        -- :5152-5153 MonoRecordCreate, :5155-5156 MonoRecordAccess,
        -- :5158-5159 MonoRecordUpdate, :5161-5162 MonoTupleCreate) changes
        -- only in that `isPureExpr` becomes `isPureExprGen kDrop` and
        -- `isPureExprDef`/`isPureDecider` become their *Gen forms …
        MonoVarKernel _ _ _ _ _ ->
            -- DEFERRED (see decision D-K below): bare kernel var in value
            -- position stays impure-conservative, exactly as today.
            False

        MonoCall _ callee args _ _ ->
            case ( kDrop, callee ) of
                ( True, MonoVarKernel _ _ home name kernelType ) ->
                    (case KernelFacts.lookup ( home, name ) of
                        Just facts ->
                            KernelFacts.droppable facts

                        Nothing ->
                            -- Whitelist discipline: unlisted ⇒ today's answer.
                            False
                    )
                        && (List.length args <= flatArrowArity kernelType)
                        && List.all (isPureExprGen kDrop) args

                _ ->
                    -- Non-kernel callees, and everything flag-off: unchanged.
                    False

        MonoTailCall _ _ _ ->
            False
```

Notes that make the arm correct rather than merely plausible:
- **Argument recursion mirrors the siblings.** `MonoList _ items _ -> List.all
  (isPureExprGen kDrop) items` (:5124-5125) is the pattern; the call arm uses the same
  `List.all` over `args`. The callee expression is deliberately *not* recursed into — it
  is the `MonoVarKernel` we just classified, and the bare-var arm returns False.
- **No separate HOF guard is needed.** kernel-opt-07's table validation V2 is
  `not f.cseSafe || (f.callTimeEffect == EffNone && not f.callsBackIntoElm && f.totality
  /= MayDiverge)`, so `cseSafe ⇒ not callsBackIntoElm` and `droppable` already excludes any
  kernel that re-enters Elm. **Note the enforcement level**: that is a *unit test*
  (`KernelFactsTest` suite 1, run by `cmake --build build --target elm-tests`), not a
  compile-time guarantee — Elm cannot fail a build on data (07 Phase 1). It blocks the
  merge, which is enough; but if V2 is ever relaxed, this arm must grow
  `&& not facts.callsBackIntoElm`. Say so in a code comment at the arm.
- **Partial applications need no special case.** A kernel call with fewer args than the
  kernel's flat arity only builds a PAP; dropping it drops an allocation, which the
  droppable bit already licenses for the saturated (strictly stronger) case.
- **OVER-application does need one, hence the arity guard.** `MonoCall` with *more* args
  than the callee's flat arity means the kernel's result is applied further — work the
  KernelFacts row says nothing about. `flatArrowArity : Mono.MonoType -> Int` is already in
  this module (declared `:1578-1582`, used at `:2224` and `:3780`), so the guard is one
  cheap term and no new helper. Keeping it also pre-clears the D-K widening below, which
  needs the same helper.
- **`MonoVarKernel` field order** is `Region prefix home name type`
  (`AST/Monomorphized.elm:1509`, comment "kernel prefix, home, name, type") — `home` is the
  **third** field and `name` the fourth, matching `CafHoist.elm:392`'s `_ _ home _ _`.

**Decision D-K — bare `MonoVarKernel` in value position stays `False` in v1.**
Criterion, both branches specified, with the denominator named: Phase 0's
**`deadBareKernelVar / deadLets`** decides (both counters specified in Phase 0; `deadLets`
exists precisely so this ratio is defined).
*If `deadBareKernelVar / deadLets < 0.005`* (expected — the shape only arises from
point-free kernel aliases like `and = Elm.Kernel.Bitwise.and`, and the H6.1 F3
partial-forward path at :3487-3507 already consumes them), keep `False`: zero risk,
whitelist-default. Record the ratio and stop.
*If it is ≥ 0.005*, widen it in a follow-up step (its own flag, its own A/B — not folded
into `kernelFactsDce`) with an arrow guard `flatArrowArity kernelType > 0` — the same
helper the over-application guard above already uses (declared `:1578-1582`; the
`n = flatArrowArity kernelType; if n > 0` idiom is at `:2221-2230`) — on the exact analogy
of the `MonoClosure` arm (`:5127-5129`, "Closure creation is pure (evaluation is not)"),
because a bare arrow-typed kernel var only mints a PAP. A non-arrow kernel *value* is never
admitted by that guard, so no unaudited nullary kernel constant can slip through.

**Step 2.2 — thread the flag and switch the one consumer.** Add to `RewriteCtx`
(:1326-1338, after `loopifyEnabled`):

```elm
    , kernelFactsDce : Bool -- kernel-opt-11 (a): widen the dead-binding purity test
```

initialize it in `initRewriteCtx` (the returned record literal is `:2250-2276`; put the
line next to `loopifyEnabled = inlineConfig.loopify` at **:2253**):

```elm
    , kernelFactsDce = inlineConfig.kernelFactsDce
```

and switch the gate at **:4780**:

```elm
                            else if
                                laterUses
                                    == 0
                                    && (if c.kernelFactsDce then
                                            isDroppableExpr bound

                                        else
                                            isPureExpr bound
                                       )
                            then
                                go earlierRev rest (bumpKernelDCE c bound) True
```

`c` is the `RewriteCtx` already in scope in `dropDeadDefs`'s `go` (`go earlierRev remaining
c anyDropped`, declared :4751, this arm at :4780-4784; `bound = getDefBound d` at
:4763-4764). **:3477
and :3499 keep calling `isPureExpr` and are untouched** — widening the partial-forward
guards is sound by the same argument (droppable ⇒ relocatable) but is a *different*
transform with a different blast radius; it is Phase 2b, out of scope, and would get its
own flag and its own A/B.

**Step 2.3 — attribution counter.** `letEliminations` (rendered `letDCE=`) already exists
and would blur old and new drops. Add `kernelLetDCE : Int` at **five** registration
points (this is the full list; verified against how `letEliminations` is wired):

1. `Metrics` type alias — `MonoInlineSimplify.elm:53-65` (after `letEliminations`, :60).
2. `InternalMetrics` type alias — `:1341-1353` (after :1348).
3. Init in `initRewriteCtx`'s metrics literal — `metrics =` at `:2261`, inner record
   `:2262-2275` (add after `letEliminations = 0`, :2268; note `arityRaised`/
   `arityRaiseSkipped` at :2272-2273 are overwritten later by `optimize`, so do **not**
   model the new counter on them).
4. Bumper, modelled on `bumpLetElimination` (`:1392-1398`) — same `let m = ctx.metrics in
   { ctx | metrics = { m | … } }` shape, bumping `letEliminations` always and
   `kernelLetDCE` additionally when `bound` matches
   `MonoCall _ (MonoVarKernel _ _ _ _ _) _ _ _`:
   ```elm
   bumpKernelDCE : RewriteCtx -> MonoExpr -> RewriteCtx
   ```
   (`optimize` returns `metrics = finalCtx.metrics` verbatim at `:892-893`; `Metrics` and
   `InternalMetrics` are structurally identical aliases, so both must gain the field or
   that line stops type-checking — which is the desired forcing function.)
5. Report render — `Builder/Generate.elm:886-887`, add
   `++ " kernelLetDCE=" ++ String.fromInt m.kernelLetDCE` immediately after the `letDCE=`
   segment. (`renderInlineReport` at :848-850 needs no change; it forwards.)

**Step 2.4 — Config plumbing.** `Compiler/Eco/Config.elm`: field in `InlineConfig`
(`:223-234`; append after `report` at :233) with an inline `--` comment in the house style
(`EcoConfig`'s `:40-45` shows the density expected); `default.inline` (`:294-318`) gets
`, kernelFactsDce = False`; `inlineDecoder` (`:376-388`) gets
`|> D.apply (D.optionalField "kernelFactsDce" D.bool default.inline.kernelFactsDce)`
**in field order** (the decoder is positional — `D.pure InlineConfig |> D.apply …`
at :378-388, so the new `D.apply` must sit at the same index as the new record field);
`hash` (`:540-541` head, base list `:543-565`, token block modelled on `:612-623`):

```elm
            ++ (if cfg.inline.kernelFactsDce then
                    [ "kfdce=1" ]

                else
                    []
               )
```

`Builder/Eco/Config.elm`: one `Task.andThen` link **appended at the END of the
`applyEnvOverrides` chain** — the chain is `:112-264` and its last link is the `cfg29` /
`ECO_BORROW_OPT` one at `:260-264`, so the new link goes immediately after :264 (the
lambda binder name is arbitrary; use `cfg30`). The `ECO_INLINE_REPORT` link at :150-154 is
the shape template. Plus `applyKernelFactsDceOverride` modelled on
`applyAggPromoteOverride` (`:272-290` — accepts `1|true|yes|on`, `0|off`, ignores anything
else); place the new `apply*Override` functions after the existing ones, each with the
`{-| \`ECO_…\`: … artifact-affecting (hash token …) -}` docstring the file uses.

**Phase 2 acceptance:**
- Flag OFF: `cmp` of the emitted `.mlir` for the self-compile workload against the
  pre-change binary is **byte-identical** (the widening is fully gated).
- Flag ON: `ECO_INLINE_REPORT=1` shows `kernelLetDCE=` > 0 iff Phase 0 said so, and
  `letDCE` grows by exactly that amount. Expect `kernelLetDCE` ≤ Phase 0's
  `deadDroppableKernelLets` (the census does not test argument purity); a *larger* number
  means the arm is firing on something the census did not classify — stop and diff.
- `DebugLogOrderingTest` green in both flavors (this is the flag-on leg Phase 1 deferred).
- Full E2E green in both flavors (commands in Gates).

### Phase 3 — (b) `computeCost` from a derived cost class.

**Step 3.1 — derived class in KernelFacts (no new stored field).** The canonical
KernelFacts record has **no** lowering-class axis, and kernel-opt-07 deliberately declines
to add one ("a cost model needs measurement, not audit"). So the class is a **derived
fact**, computed like `droppable`/`gcLeafEligible`, added to `KernelFacts.elm` beside them
(07 Phase 1's "DERIVED FACTS" block). **Registration:** add `CostClass(..)` to the type
group and `costClass` to the function group of that module's `exposing` list — 07's list is
`( KernelFacts, CallTimeEffect(..), GcAlloc(..), Totality(..), ParamMode(..), lookup,
lookupSymbol, rows, canTriggerGC, gcLeafEligible, droppable, hoistable, validationErrors )`
and Elm has no implicit export. `GcNone` is referenced from inside the module, so no import
changes anywhere:

```elm
{-| kernel-opt-11 (b): cost class, DERIVED — never stored. No `CInline` case on
purpose: whether a symbol lowers to an inline op is a property of
Generate.MLIR.Intrinsics, not of the audit, and is queried there.
-}
type CostClass
    = CGcLeaf -- plain leaf call: no Elm GC, no C++ heap traffic, no callback
    | CAlloc -- allocates on the Elm heap or the C++ heap
    | CHof -- re-enters Elm through a user closure


costClass : KernelFacts -> CostClass
costClass f =
    if f.callsBackIntoElm then
        CHof
    else if f.gcAlloc /= GcNone || f.cppAlloc then
        CAlloc
    else
        CGcLeaf
```

**Step 3.2 — inline-op oracle.** The ground truth for "this call lowers to an op, not a
call" is `Compiler.Generate.MLIR.Intrinsics.kernelIntrinsic : Name -> Name -> List
Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic` (`Intrinsics.elm:318-340`, dispatching
on home `Basics|Bitwise|Utils|JsArray|Char|String`). Call it rather than duplicating a
name list. Cycle check (done, 2026-08-10): `Intrinsics` imports `Mono`, `Data.Name as
Name`, `Generate.MLIR.Context as Ctx`, `Ops`, `Types`, `Dict`, `Mlir.Mlir`
(`Intrinsics.elm:12-18`); `Context` imports `Borrow.Facts`, `KernelAbi`, `Types`, `Mode`
(`Context.elm:60-71`); `Borrow.Facts` imports only `Dict`/`Set` (`Facts.elm:25-26`);
`KernelAbi` only `Mono`/`Types`/`Mlir`/`Crash` (`:36-39`); `Types` only
`Mono`/`Name`/`Dict`/`Mlir` (`:63-66`); `Mlir.Mlir` only `Dict`/`Loc`/`OrderedDict`
(`:44-46`). None reaches `MonoInlineSimplify` (whose only two importers are
`Builder/Generate.elm:77` and `Generate/MLIR/Backend.elm:27`), so
`import Compiler.Generate.MLIR.Intrinsics as Intrinsics` is acyclic.

**Call this out in review: it is the FIRST `GlobalOpt.* → Generate.*` import in the tree**
(`grep -rn '^import Compiler.Generate' compiler/src/Compiler/GlobalOpt/` returns nothing
today; the existing edge runs the other way, `Generate/MLIR/Context.elm:65` →
`GlobalOpt.Borrow.Facts`). It is legal and acyclic, but it inverts the pipeline's usual
layering and transitively pulls `Generate.Mode` → `Generate.JavaScript.Name` /
`Elm.Compiler.Type.Extract` into `MonoInlineSimplify`'s dependency cone (all already in the
same executable, so no new build unit and no `cmake --preset` reconfigure). **If a reviewer
rejects the layering**, the fallback is a `Config.InlineConfig`-carried predicate: pass
`kernelIsIntrinsic : Name -> Name -> List Mono.MonoType -> Mono.MonoType -> Bool` into
`optimize` from `Builder/Generate.elm:829` (which is already downstream of both layers) and
store it in `RewriteCtx` — same oracle, no import. Decide before Step 3.3, not during.

`kernelIntrinsic` is **type-directed** (e.g. `( "add", [ Mono.MInt, Mono.MInt ] )` at
`Intrinsics.elm:365-366`), which is exactly right post-mono; treat `Nothing` as "not
inline" (conservative). Note the type-var caveat the module itself records
(`Intrinsics.elm:345-349`): a result type can still be an `MVar` in a polymorphic context,
which the intrinsic arms handle via `Ctx.isTypeVar` (`Context.elm:171`). That only ever
costs a *cost-model* mismatch, never correctness.

**Step 3.3 — thread config into `computeCost`.** Signature becomes
`computeCost : Config.InlineConfig -> MonoExpr -> Int` (precedent: `residualTaxonomy`
`:208-209`, `buildLoopifiables` `:1514-1515` already take `Config.InlineConfig`);
`computeCostDef` (:1280-1281) and `computeCostDecider` (:1290-1291) take it too. Only
**two** non-recursive call sites exist and both already have `inlineConfig` in scope:
`:1531` (inside `buildLoopifiables`, whose param is literally `inlineConfig`) and `:2151`
(inside `initRewriteCtx`, same). Every other mention (`:1240/1243/1246/1249/1252/1255/
1258/1265/1268/1271/1274/1277/1284/1287/1294/1300/1304/1305`) is internal recursion.
`computeCost` is not exported — the module's `exposing` list (`:1`) is `(Metrics, optimize,
buildBodyLookup, countClosures, residualTaxonomy, functionResultCensus)`.

```elm
        MonoVarKernel _ _ _ _ _ ->
            1

        MonoCall _ ((MonoVarKernel _ _ home name _) as func) args resultTy _ ->
            if cfg.kernelCostClasses then
                kernelCallCost cfg home name args resultTy
                    + sumBy (computeCost cfg) args

            else
                5 + computeCost cfg func + sumBy (computeCost cfg) args

        MonoCall _ func args _ _ ->
            5 + computeCost cfg func + sumBy (computeCost cfg) args


{-| Cost of the CALL ITSELF (args priced by the caller). Today's value for
every kernel is 6 (= 5 + the MonoVarKernel arm's 1); an unlisted symbol keeps
exactly that, so the class table only ever moves audited rows.
-}
kernelCallCost : Config.InlineConfig -> Name -> Name -> List MonoExpr -> Mono.MonoType -> Int
kernelCallCost cfg home name args resultTy =
    case Intrinsics.kernelIntrinsic home name (List.map Mono.typeOf args) resultTy of
        Just _ ->
            cfg.kernelCostInline

        Nothing ->
            case KernelFacts.lookup ( home, name ) of
                Nothing ->
                    6

                Just facts ->
                    case KernelFacts.costClass facts of
                        KernelFacts.CGcLeaf -> cfg.kernelCostGcLeaf
                        KernelFacts.CAlloc -> cfg.kernelCostAlloc
                        KernelFacts.CHof -> cfg.kernelCostHof
```

Placement: the two `MonoCall` arms replace the single one at `:1245-1246`, and the
specific arm must come **first** (Elm matches top-down; a bare `MonoCall _ func args _ _`
above it would shadow). Config plumbing for the five knobs mirrors Step 2.4; hash token
`"kcc=" ++ i ++ "/" ++ g ++ "/" ++ a ++ "/" ++ h`, emitted only when
`kernelCostClasses` is on, so every A/B leg is a distinct cache key.

`Mono.typeOf` is O(1) (`AST/Monomorphized.elm:1718-1773`, one pattern match returning the
stored annotation; `MonoCall`'s type is its 4th field, `Monomorphized.elm:1512`). It is
exposed — `Mono` is already imported here as
`Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), MonoGraph(..), MonoNode(..),
SpecId)` (`:24`), and `Mono.typeOf` is used qualified elsewhere in the tree
(e.g. `CafHoist.elm`), so no import change.

**Initial constants (all four are hypotheses, none is committed):**
`kernelCostInline = 1`, `kernelCostGcLeaf = 3`, `kernelCostAlloc = 5`,
`kernelCostHof = 10`. Today's uniform value is **6**, which is also the unlisted default.

**Step 3.4 — the A/B protocol. One constant per run; never batch.**
Workload/binary/cache discipline verbatim from `benchmarks/tier2-opt.md:35-96`
(cold-cache Stage 7a, `rm -rf "$BK/eco-stuff"` before every leg, `~/.eco` never deleted,
warmup leg then measured leg, gates never mixed into a benchmark run).

**Which side the env goes on — do not confuse the two knobs** (tier2-opt.md:54-58,
"**Two independent engine knobs** (do not confuse): the **build engine** … vs the
**workload engine**"). The cost flags exist on both sides and mean different things:

| leg | env set at | what varies | what must stay fixed |
|---|---|---|---|
| **null test (3.4.0)** | the **workload** `make` run | the emitted `.mlir` of the workload | one binary, used for both legs |
| **wall legs (3.4.1-4)** | the **build** of `eco-compiler` (tier2-opt.md Phase 1) | the tested binary's own code | workload env constant: `ECO_MONO_ENGINE=subst`, cost env **UNSET** at the `make` run |

- **3.4.0 NULL TEST (mandatory first; workload-side).** One binary. Leg A: cost env unset.
  Leg B: `ECO_KERNEL_COST_CLASSES=1 ECO_KERNEL_COST_INLINE=6 ECO_KERNEL_COST_GCLEAF=6
  ECO_KERNEL_COST_ALLOC=6 ECO_KERNEL_COST_HOF=6`. `rm -rf "$BK/eco-stuff"` before each.
  `cmp` the two workload `.mlir` files: **must be byte-identical** (the two legs *are*
  cache-disjoint — `kcc=6/6/6/6` is a distinct `Config.hash` — so this is a real
  recompile, not a cache hit). A diff means the arm is not arithmetically equivalent to
  `5 + 1 + args`; fix before touching any constant.
- **3.4.1 … 3.4.4 (build-side)**, in this order (cheapest blast radius first):
  `kernelCostInline` 6→1; then `kernelCostGcLeaf` 6→3; then `kernelCostAlloc` 6→5; then
  `kernelCostHof` 6→10. Each step keeps the previously *accepted* values and moves exactly
  one knob. **Ninja is env-blind** (tier2-opt.md:74-77, discovered Run B): with no source
  change an env-only flavor change does NOT rerun Stage 5, so every leg must begin with
  `rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"; rm -rf "$BK/eco-stuff"`
  before the `cmake --build build --target eco-compiler`. Skipping this measures the
  previous leg's binary and looks like a clean "flat".
- **Per step, record in this file's ledger:** wall (median of 3 measured legs), Max RSS,
  **major-GC count** (GC dump in the leg's stdout — the trigger lottery makes a wall
  number without its major count uninterpretable), the tested binary's own emitted MLIR
  size (`$BK/bin/eco-compiler.mlir` — **this** is the artifact the cost change resizes;
  the workload's `.mlir` is byte-identical across build-side legs by construction and is
  the sanity `cmp`, not the metric), and `inlined=` / `letDCE=` / `closuresRemaining=`
  from an `ECO_INLINE_REPORT=1` **build** leg (run separately from the timed leg — the
  report writes stderr from inside the compile that produces the binary). The `inlined=`
  delta is the "inline-decision delta count" this plan owes.
- **Acceptance criterion per constant (both branches specified):** KEEP the new value iff
  median wall improves by **≥1.5 %** with majors not increasing, **or** wall is flat
  (|Δ| < 1.5 %) and `$BK/bin/eco-compiler.mlir` shrinks ≥1 % **with the workload `.mlir`
  still `cmp`-identical**. Otherwise REVERT that knob to 6, record the negative result,
  and continue the sweep with the next knob. `|Δ| < 1.5 %` is FLAT by fiat for this
  workload — do not read a 0.4 % move as a win.
- **`elm-aws-codegen` canary timed on every step** (`annotateCallStaging` is
  O(2^let-depth); cost changes move inlining, and inlining moves let depth).

**Phase 3 acceptance:** null test byte-identical; every accepted constant has its own
recorded A/B row; the final vector is written into `default.inline` **only if** at least
one knob was accepted, otherwise `kernelCostClasses` stays default-off with the negative
ledger recorded (a legitimate, honest outcome).

### Phase 4 — align CafHoist/CafDedupe justification (no behaviour change).

Per row 5's fix column (`design_docs/kernel-boundary-reduction.md:2007`, which says
CafHoist/CafDedupe "*keep* their behavior but justify it from the table instead of
`home == "Debug"` — one line, details in the attributes section"), `CafHoist.elm:392-393`
keeps `hasDebug = home == "Debug"` as its *behaviour* but gains a comment citing
`KernelFacts` + `design_docs/debug-log-ordering-policy.md` D-1/D-3 as the reason it is the
right conservative test for an unlisted-tolerant default-off pass; `CafDedupe.oneRound`
(`CafDedupe.elm:92-119`) likewise. Do **not** narrow either pass here — kernel-opt-07
Phase 7 and its "Default-policy regression (binding, §6.F)" trap are explicit that
narrowing a default-off pass is itself a regression, and that the fix for their optimism is
*listing the effectful rows*. Two comments total, no behaviour change, no test change; both
passes stay default-off at `Config.elm:321`.

## Traps & risks

- **Totality is load-bearing, not decoration.** Dropping a call that throws or diverges
  changes behaviour. Canonical ledger example (kernel-opt-07): `modBy 0` — the C++ body
  THROWS (`Basics.cpp:92-103`) where the intrinsic returns 0. Hence `droppable` requires
  `cseSafe AND totality == Total`, never `cseSafe` alone.
- **`--optimize` gives no Debug latitude on the native path** (evidence section). Any
  reasoning of the form "Debug can't be here, we're optimizing" is wrong for the MLIR
  backend and is forbidden by policy D-5.
- **Positional decoder.** `inlineDecoder` is `D.pure InlineConfig |> D.apply …`
  (`Config.elm:376-388`): a new field appended to the record but inserted at the wrong
  index in the decoder chain silently mis-assigns *every* subsequent field. Add field and
  `D.apply` at the same position, and eyeball the pairing. Today's pairing is
  threshold/whitelist/blacklist/maxPerFunction/fixpointIterations/hofThreshold/loopify/
  arityRaise/raiseAppliedShareMin/report (record `:224-233` ↔ decoder `:379-388`); appending
  six fields means appending six `D.apply` lines in the same order after `:388`.
  There is no test that catches a mis-pairing — every field is the same `Bool`/`Int` shape,
  so a swap type-checks. The cheap check: set each new key to a non-default value in an
  `eco-config.json` once and confirm `Config.hash` changes as expected.
- **`Metrics` vs `InternalMetrics`.** Two structurally identical aliases joined by
  `metrics = finalCtx.metrics` (:892-893). Adding the counter to only one is a compile
  error — good — but adding it to neither and bumping a nonexistent field is not caught
  by any test; the report line is the observable check.
- **Inliner-threshold blast radius.** Row 5 impact column: "any new cost constants must
  be A/B'd — inliner-threshold changes have historically large blast radius". One
  constant per A/B; never batch (b) tunings with (a) or with each other. `hofBudget =
  max threshold hofThreshold` = 25 (`:2124-2125`, `Config.elm:295/304`) means a HOF
  candidate has 2.5× the general budget — raising `kernelCostHof` to 10 can evict bodies
  from *both* budgets at once.
- **`computeCost` is on a hot path.** It runs per inline candidate (:2151) and per
  loopify candidate (:1531). The kernel arm adds a `kernelIntrinsic` match + a `Dict.get`
  per kernel call, and `kernelIntrinsic` itself allocates a `List.map Mono.typeOf args`
  per call node. Watch Stage-7a *compile* wall in the Phase-3 legs, not just the
  compiled binary's wall; if the added lookup shows up, memoize per `(home, name)` in
  `RewriteCtx` — but only on evidence. (Note the two measurements are different legs: the
  build-side legs measure the *produced binary*; compile-wall regression shows up as the
  `cmake --build … --target eco-compiler` step getting slower, so time that step too.)
- **Elm has no re-export** (kernel-opt-07's first trap): `CostClass(..)` must be added to
  `KernelFacts`'s own `exposing` list, and consumers pattern-match
  `KernelFacts.CGcLeaf`/`CAlloc`/`CHof` qualified. Do not try
  `type alias CostClass = KernelFacts.CostClass` in `MonoInlineSimplify` — constructors do
  not travel through an alias into pattern position.
- **Prior-calibration trap:** wall in this repo tracks retention and deleted per-op work,
  not call/site counts (4× flat-wall lesson: preserve-cc, gc-leaf pilot at 64.1 % dynamic
  coverage, capacity-check hoisting −5.32 MB, compare phases). Removing a *dead* call does
  delete real work, but Phase 0 may show the dead-call population is tiny — do not promise
  wall from (a).
- **Stale-census trap:** the dynamic census predates the Aug 10 cmp_order/peephole ship;
  `Utils_compare`/`getOrder` rows are STALE. Cost-class tuning priorities must not be
  ranked off those rows.
- **Harness cache is mtime-based** even though the flag is hash-keyed: `touch
  /work/test/elm/src/*.elm` before any flag-on E2E gate (memory: *eco LSS design*).

## Dependencies

- **Hard: `kernel-opt-07-kernel-facts-table.md`** — supplies `Compiler.GlobalOpt.
  KernelFacts` keyed `(home, name)`, the `cseSafe`/`totality`/`gcAlloc`/`cppAlloc`/
  `callsBackIntoElm` axes, the derived `droppable`, and the V2 validation
  (`cseSafe => EffNone AND not callsBackIntoElm AND totality /= MayDiverge`) this plan's
  arm relies on instead of re-deriving the HOF guard — enforced as an **elm-test**
  (`KernelFactsTest` suite 1), not a compile-time property. Nothing here lands first. This
  plan consumes 07's derived helpers (`droppable`) and never re-derives from raw fields,
  per 07's pinned contract item 2. The one addition it makes to that module is the
  **derived** `CostClass`/`costClass` plus two `exposing` entries — no new stored field, so
  the cross-plan record schema is unchanged.
- **`kernel-opt-13-mono-cse.md` (SOFT)** — owns the `ECO_CSE_REPORT=1` census Phase 0
  rides on (13 §0.5 "kernel-opt-11 ride-along", `cse-dce:` output line), to which this plan
  adds the `deadBareKernelVar` and `deadLets` counters; and shares the Phase-1 policy file
  (`design_docs/debug-log-ordering-policy.md`, drafted here, referenced there — 13 Phase 2
  says so explicitly and does not re-draft it). **Not a build dependency:** this plan
  imports no 13 module (see Phase 2's "Why 11 reads `KernelFacts` directly"), and Phase 0
  has a stated fallback if 13's D-C gate closes 13 at Phase 1.
- **kernel-opt-08/09/12** — sibling consumers of the 07 table. No code coupling here:
  08/09 consume the `eco.gc_leaf` **declaration** attr (derived from `gcLeafEligible`) and
  09's module-level marking pass stamps the call-local `eco.callee_gc_leaf`; 12's
  `eco.cse_safe` per-call attr is a separate Elm-level channel. This plan touches no MLIR
  attribute. It does share the `CAlloc`/`CGcLeaf` taxonomy with 08's stampable set — both
  derive from `gcAlloc`/`callsBackIntoElm`, so they cannot drift.
- External: none beyond the standard toolchain.

## Expected impact

**Honest expectation: flat wall; this is an enabling/code-quality item.** Its value is
(1) unblocking Mono-level simplification — dead pure kernel lets become removable, and the
inliner stops mispricing kernel bodies in both directions; (2) ending the row-5
contradiction with one shared effect model; (3) the written Debug policy retires a
twice-owed soundness debt for the whole CSE/DCE/fusion family, and pins a fact the tree
contradicts today (the `Debug.cpp:47-48` comment). Any wall movement would come from (b)
changing inlining decisions — possible in either direction, which is exactly why each
constant is A/B'd solo. No direct wall claim is made. If Phase 0 reports a near-zero
dead-droppable population, (a) still lands (contradiction + enabling value) and this
section is amended with the measured number rather than retrofitted with a story.

## Gates

- **E2E, run ONCE, teed, then grepped — never re-run to re-read:**
  ```bash
  cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
  grep -E 'FAIL|Failed|error:' /tmp/test_output.txt | head -50
  ```
  (`full`, never `check` — this change regenerates `.mlir`.) Then the flag-on leg:
  ```bash
  touch /work/test/elm/src/*.elm
  ECO_KERNEL_FACTS_DCE=1 cmake --build build --target full 2>&1 | tee /tmp/test_output_kfdce.txt
  grep -E 'FAIL|Failed|error:' /tmp/test_output_kfdce.txt | head -50
  ```
  Targeted: `TEST_FILTER=DebugLogOrdering cmake --build build --target full`.
- **Compiler front-end:** `cmake --build build --target elm-tests 2>&1 | tee
  /tmp/elm_tests.txt` (the 12 known pre-existing typechecker-gate failures are the
  baseline). Run **serially** with the E2E leg — concurrent suites corrupt `~/.eco`
  typed-artifacts.dat (memory: *eco E2E/unit cache race*).
- **Formatting:** `build/toolchain/bin/elm-format --validate` clean on every touched
  `.elm` file (`compiler/src/Compiler/GlobalOpt/{KernelFacts,MonoInlineSimplify}.elm`,
  `compiler/src/Compiler/Eco/Config.elm`, `compiler/src/Builder/Eco/Config.elm`,
  `compiler/src/Builder/Generate.elm`). The sketches above are written for readability —
  e.g. `KernelFacts.CGcLeaf -> cfg.kernelCostGcLeaf` on one line — and elm-format will
  reflow them; take its output, do not fight it.
- **Heap-validate suite green.** `ECO_HEAP_VALIDATE` is a **CMake option**
  (`CMakeLists.txt:84-89`), **not** an environment variable — prefixing `cmake --build`
  with `ECO_HEAP_VALIDATE=1` does nothing. Use the already-configured tree
  `/work/build-val` (`build-val/CMakeCache.txt:327` = `ECO_HEAP_VALIDATE:BOOL=ON`), the
  same way kernel-opt-02 G4 does:
  ```bash
  cd /work && cmake --build build-val --target full 2>&1 | tee /tmp/validate_output.txt
  grep -cE "^ok |PASS" /tmp/validate_output.txt
  grep -E "FAILED|abort" /tmp/validate_output.txt
  ```
  1632/1632 is the current baseline. (If `build-val` is missing, create it once:
  `cmake -S . -B build-val -DECO_HEAP_VALIDATE=ON` with the `build` preset's compiler
  settings — no preset sets this option.) For the flag-on leg, prefix the *build* with
  `ECO_KERNEL_FACTS_DCE=1` as in the E2E gate above.
- **Self-host bootstrap** (`cmake --build build --target bootstrap`,
  `compiler/CMakeLists.txt:1026-1032` — it drives the Stage 4b JS fixed point, the Stage 8c
  native fixed point and the Stage 9b unified-eco self-compile):
  ```bash
  cd /work && cmake --build build --target bootstrap 2>&1 | tee /tmp/bootstrap_output.txt
  grep -nEi "fixed point|identical|differ|FAILED|Stage (4b|8c|9b)" /tmp/bootstrap_output.txt
  ```
  Two distinct obligations:
  - *Default-off (the shipped configuration):* byte-identity at the existing fixed point
    must hold **exactly** — both fixed points, Stage 4b JS and Stage 8c native. Any diff
    means the flag leaks (i.e. some code path reads `KernelFacts` outside the gate).
  - *Flag-on:* output changes **legitimately** (that is the transform). The gate becomes:
    bootstrap **converges to a NEW fixed point** (Stage 8c self-reproducing, byte-identical
    to its own successor), the resulting compiler passes full E2E, and the `.mlir` diff is
    attributable to removed dead lets (`kernelLetDCE` count ≈ removed bindings) and, for
    Phase 3, to changed inline decisions (`inlined=` delta) — nothing else. Say which of
    the two regimes the change is in, in the commit message.
- **Wall A/B with major-GC counts recorded**, methodology `benchmarks/tier2-opt.md:35-96`.
  Both legs below start with the ninja-env-blind reset (`rm -f "$BK/bin/eco-compiler.mlir"
  "$BK/bin/eco-compiler"; rm -rf "$BK/eco-stuff"`, tier2-opt.md:74-77) — an env-only flavor
  change does not otherwise rerun Stage 5. For (a), two legs that separate the two effects
  the flag has:
  - *A2-binary* (**build-side**) — binaries built with `ECO_KERNEL_FACTS_DCE=1` vs `=0`,
    workload run with the flag **off** in both. The workload `.mlir` must be `cmp`-identical
    (proves the walls are comparable); the delta is "does the DCE'd compiler run faster".
  - *A2-workload* (**workload-side**) — one flag-on binary, workload run flag-off vs
    flag-on. Output differs by design; records the compile-time cost of the table lookups
    and the emitted-size delta. Note the two legs are cache-disjoint (`kfdce=1` is in
    `Config.hash`), so both are genuine cold compiles.
  For (b), one A/B per constant per Step 3.4 (build-side), plus the 3.4.0 null test
  (workload-side).
- **`elm-aws-codegen` canary timed on every Phase-3 leg** and on the (a) flag-on leg
  (`annotateCallStaging` O(2^let-depth); DCE and cost changes both move let structure).
  Command: Phase 0's aws invocation with `/usr/bin/time -v`; gate = completes, wall within
  3 % of the flag-off leg.
- **Item counters:** the Phase-0 `cse-dce:` line (`deadLets`, `deadPureLets`,
  `deadDroppableKernelLets`, `deadBareKernelVar`, + the per-symbol `cse-dce top:` line);
  `kernelLetDCE` / `letDCE` before and after (a) via `ECO_INLINE_REPORT=1`; `inlined=`
  delta per (b) step. All recorded in this file's *Results*.

## Results

(Phase 0 census table, per-constant A/B ledger, and the D-K decision get appended here as
they are measured. Empty until Phase 0 runs — deliberately, so an unmeasured claim cannot
be mistaken for a measured one.)

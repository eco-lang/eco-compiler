# Kernel devirt: move the arity pin into KernelFacts and grow the table

**Status: IMPLEMENTED (2026-08-20), waves 0-3; see the execution record at the end.** Completes LSS_016's whitelist, which
is still at v1 — one entry — while the census that measures its gap reports 157
eligible call sites. All code refs verified at HEAD 2026-08-20.

---

## §0 Where things stand

E9.2 kernel devirtualization (LSS_016) rewrites an indirect call whose callee is
a plain var with a singleton `LSet [k|home.name]` into a direct kernel call,
provided `(home, name)` is on a whitelist that pins the exact arity. The
whitelist is `Translate.kernelDevirtArity`:

```elm
kernelDevirtArity home name =
    if home == "List" && name == "cons" then Just 2
    else Nothing
```

with a companion `kernelDevirtShapeOk` doing a REP-level sanity check on the
derived ABI (for `cons`: neither tail nor result may be an unboxed scalar,
because `cons_Int` would then read the tail list pointer as a raw i64 — a
CGEN_038 mismatch).

**The gap is measured, not guessed.** `lssStats.kernelMissHist` exists precisely
to size it ("NON-whitelisted kernel singleton call sites, whitelist growth").
Run AA, self-compile:

    Scheduler.fail=74  Basics.not=42  Scheduler.succeed=13  Basics.add=4
    String.length=4  Utils.append=4  Utils.equal=4  Json.wrap=3
    String.toLower=3  String.trim=3  String.fromList=2  Basics.round=1

**157 sites across 12 kernels** where LSS had already proved the singleton and
membership was the only thing blocking the rewrite.

## §1 The consolidation question, answered with the table's actual contents

The suggestion is to put the arities in `KernelFacts` so kernel knowledge lives
in one audited place rather than an if-else chain. That is the right direction —
`KernelFacts` is already the repository's single audited source of per-kernel
semantic facts, with `( Name, Name )` keys, mandatory C++ evidence anchors, a
`lookup`, a `rows` walk, and a `validationErrors` self-check. But the naive form
of it does not work, for a reason worth stating before any code moves:

**`params = []` is overloaded.** The field's own comment reads
`params : List ParamMode -- [] == borrow axis NOT audited`, so
`List.length params` is not arity — it is arity *or* "nobody looked". Measured:
**34 of the 52 rows carry a non-empty `params`**, and among the twelve census
misses the two biggest (`Scheduler.fail`, `Scheduler.succeed`) are exactly the
`params = []` kind. Deriving arity from `params` would therefore silently
mis-arity the highest-value entries in the list, which is the one failure mode
LSS_016's design exists to prevent.

So: consolidate, but with an **explicit** field.

### §1.1 There are already four places that know a kernel's arity

Recording this because "one place" is the goal and the count is not one:

| source | covers | authority |
|---|---|---|
| package aliasing annotation (`map2 : … -> …`) | ~191 aliased kernels | the real Elm type |
| `Compiler.Type.KernelIntrinsics` (TYPE_KERNEL_001) | 4 rows today | the eco C++ contract |
| `KernelTypeEnv` (PostSolve, first-usage-wins) | whatever was seen | inference artefact, not a fact |
| `Translate.kernelDevirtArity` | 1 row | hand-pinned |

`elm-kernel-cpp/src/KernelExports.h` holds 337 C-linkage declarations and is the
ground truth for the *export* arity, which is NOT always the Elm arity —
`Debug.toString` takes an injected `type_id`, `Json.emptyArray` is applied to
`()` in Elm but takes zero C++ parameters. A row must pin the **Elm-visible
call arity**, which is what the site's argument count is compared against.

The plan does not try to unify all four. It puts the devirt pin in `KernelFacts`
and adds a test that where an intrinsic annotation also exists the two agree —
the same anti-drift trick `KernelLicenseTest` already uses for `TransportsAs`
shapes versus `KernelIntrinsics` annotations.

## §2 The design

### 2.1 `KernelFacts` gains an explicit, opt-in devirt field

```elm
type DevirtPolicy
    = DevirtNo                        -- default; not registered
    | DevirtAt Int ShapeGuard         -- Elm-visible call arity + REP guard

type ShapeGuard
    = ShapeAny                        -- every legal ABI variant is safe
    | ShapeNoUnboxedScalarAt (List Int)  -- these positions (-1 = result) must not derive as unboxed scalars
```

added to the `KernelFacts` record as `devirt : DevirtPolicy`, defaulting to
`DevirtNo` in both `unaudited` and `auditedPure`.

`Translate.kernelDevirtArity` and `kernelDevirtShapeOk` become thin readers over
`KernelFacts.lookup`, so the if-else chain disappears and the registration lives
beside the purity evidence that justifies it.

**Membership stays EXPLICIT — do not derive it.** It is tempting to compute
eligibility as `cseSafe && callTimeEffect == EffNone && totality == Total`, and
that is exactly the wrong move: `KernelFacts`'s whitelist discipline is
"unknown ⇒ each consumer keeps its OWN pre-table behaviour", and auto-deriving
would enrol kernels audited for a *different* question. `DevirtAt` is a
per-kernel registration whose evidence must mention the arity, same as
LSS_016 requires today.

### 2.2 `validationErrors` grows two checks

The table already self-checks (duplicate keys, evidence anchors). Add:

- a `DevirtAt n _` row must have `n >= 0`, and where `params` is non-empty,
  `List.length params == n` — catching the mis-arity the overload above would
  otherwise hide;
- a `DevirtAt` row must carry evidence (it is a soundness registration).

Plus a unit test cross-checking `DevirtAt n` against the arrow-spine length of
`KernelIntrinsics.lookup`'s annotation wherever both exist.

## §3 Wave 0 RESOLVED (2026-08-20): purity is not required, but it becomes load-bearing

**Question:** LSS_016 said "each entry must be pure (a plain allocator/value
function) and pins its exact arity". Is the purity half real?

**Answer: no — and yes, but not in the way the wording implies.**

### The rewrite needs no purity at all

`Translate.translateIndirectCallBody`'s `DevirtKernel` arm emits

```elm
Mono.MonoCall region (Mono.MonoVarKernel region kernelPrefix home name funcMonoType)
    monoArgs resultMonoType Mono.defaultCallInfo
```

over the **already-translated** `monoArgs`, at the same program point. The only
thing discarded is `monoFunc` — a var read. The sibling `DevirtGlobal` arm states
the same reasoning in its own comment ("monoFunc's own translation (a var read)
already happened, so state effects are identical"). So the kernel's effects,
their count and their order are preserved **by construction**. An effectful
kernel called directly is the same call it was called indirectly.

### What devirt actually does is amplify capability

An indirect call is **opaque about which kernel it is** — nothing downstream can
tell. A direct `MonoVarKernel` call **exposes the identity**, and three
DEFAULT-ON purity-driven consumers key on exactly that:

| consumer | gate | what it may then do |
|---|---|---|
| `MonoInlineSimplify` dead-let gate (`kernelFactsDce`) | `KernelFacts.droppable` + pure args + arity guard | DELETE a dead kernel call |
| `CsePurity` / `MonoCse` | audited `cseSafe` | MERGE two calls into one |
| `Generate/MLIR/Ops.calleeIsDroppable` (`callPurityAttrs`) | `lookupSymbol >> droppable` | stamp `eco.cse_safe`, licensing MLIR merge + DCE |

So devirtualization promotes a kernel's `KernelFacts` purity row **from inert to
load-bearing at that site**. Before, a wrong `cseSafe` on a kernel reached
indirectly was unexploitable; after, MLIR may merge or delete the call.

### The boundary, restated

> **arity + ABI shape guard + a purity row that is CORRECT IF PRESENT.**

All three consumers apply whitelist discipline (unlisted or `unaudited` yields
False), so a kernel with no audited row is **safe-but-unoptimized**, not unsound
— it gets the dispatch removal and nothing else. Purity is therefore a
**precondition on the existing row**, not a filter on which kernels may be
registered. LSS_016 amended accordingly.

### What this changes for the growth list

**All twelve census misses are registrable in principle**, Scheduler included.
The per-entry work splits in two, and only the first half is mandatory:

1. **Mandatory:** pin the Elm-visible arity, argue the ABI shape guard.
2. **Conditional:** if the kernel has an *audited* `KernelFacts` row, re-confirm
   it, because devirt makes it exploitable. No row, or an `unaudited` one ⇒
   nothing to confirm, and nothing gained beyond the dispatch removal.

Concretely:

- **`Scheduler.succeed` / `fail` (87 of 157 sites)** carry `auditedPure` rows
  with `gcAlloc = GcFixed 1` and C++ evidence (`Scheduler.cpp:123-126` /
  `:139-142`), so `cseSafe` and `droppable` are already True. The question is not
  "are they pure enough to devirt" — it is "is that existing claim right?", a
  re-read of two four-line C++ functions. Note the apparent tension with LSS_022,
  which REJECTS both for Task storage: different axis, different question.
  Set-flow asks "can a function value be retained here?"; purity asks "is the
  call referentially transparent and droppable?". Both answers can be yes.
- **`String.toLower` / `trim`** sit on the `unaudited` base, so `cseSafe` and
  `droppable` are False. Registering them is safe and buys the dispatch removal
  only; upgrading their rows is separable, optional work.
- **`Basics.not/add/round`, `String.length/fromList`, `Utils.equal/append`,
  `Json.wrap`** — the scalar batch. `Utils.equal`, `Utils.append` and
  `String.length` have audited rows to re-confirm; the rest have none.

## §4 Waves

- **Wave 0 — DONE (§3).** LSS_016 amended; no code changed.
- **Wave 1 — mechanism.** `DevirtPolicy` on `KernelFacts`, `cons` migrated
  verbatim (`DevirtAt 2 (ShapeNoUnboxedScalarAt [ 1, -1 ])`), `Translate`'s two
  functions reduced to lookups, `validationErrors` extended, drift test against
  `KernelIntrinsics` added. Gate: byte-identical `out.mlir` — this wave moves one
  row between tables and must change nothing.
- **Wave 2 — Scheduler FIRST, not last.** `succeed`/`fail` are 87 of the 157
  sites and their arity is trivial (1 each). Precondition per §3: re-read
  `Scheduler.cpp:123-126`/`:139-142` and confirm the `auditedPure` claim, since
  devirt makes it exploitable by MLIR merge/DCE. This is where the measured value
  is; the original plan scheduled it last on a purity assumption Wave 0 refuted.
- **Wave 3 — the scalar batch**, 70 sites. Arity from the Elm annotation (NOT
  `KernelExports.h`, per §1.1) plus a shape-guard argument each. Re-confirm the
  three with audited rows; the rest register as safe-but-unoptimized.
- **Measurement each wave:** `kernelMissHist` shrinks by the registered sites and
  `devirtKernel` rises by the same amount — the two moving together is the check
  that a row took effect. One `benchmarks/lss-opt.md` row for waves 2-3 combined.
  Unlike the licensing arc this removes dispatches AND opens CSE/DCE/MLIR-merge
  on 87 call sites, so a wall effect is plausible and the run earns its cost.

## §5 Risks

1. **A wrong arity is a miscompile, not a missed optimization** — the derived
   ABI would misread arguments (the `cons_Int` tail-pointer case). Mitigated by
   the explicit field, the `params`-agreement check, the intrinsics cross-check,
   and per-row evidence.
2. **`params = []` overloading** is the trap this plan exists to avoid encoding;
   if a later change makes `params` mean "arity", these two meanings must be
   split first.
3. **Wave 2 rows sitting on `unaudited`** carry conservative purity defaults
   that look like facts. Registering one without re-reading its C++ imports an
   unaudited claim into a soundness boundary.
4. **Shape guards are per-kernel REP arguments**, not a checkbox.
   `ShapeNoUnboxedScalarAt` covers the `cons` pattern; a kernel whose hazard is
   different needs its own constructor rather than a forced fit.


---

# EXECUTION RECORD — waves 1-3 (2026-08-20)

## Wave 1 — mechanism

`KernelFacts` gains `devirt : DevirtPolicy` (`DevirtNo | DevirtAt Int
ShapeGuard`, with `ShapeGuard = ShapeAny | ShapeNoUnboxedScalarAt (List Int)`,
`-1` meaning the result), plus `devirtOf` folding in the whitelist default.
`Translate.kernelDevirtArity` / `kernelDevirtShapeOk` / `kernelDevirtEmissionOk`
became readers over that field, and the cons-specific `consTailAndResult` was
replaced by a generic `peelArrow` handling curried, flat and mixed arrow forms.
`validationErrors` grew `devirtErrors`: non-negative arity, agreement with
`params` **when non-empty** (the `[]`-overload from §1), mandatory evidence, and
guard positions in range.

One generalization worth flagging: the deep **CNumber-freedom** check, which was
cons-specific, now applies to EVERY registered kernel. An unsettled site can
have its layout collapsed later by the demand-closing rewrite, leaving a frozen
kernel call ill-typed; declining costs only a dispatch and
`declinedKernelCNumber` measures what it costs. Observed firing once on the
`Wide` probe, so it is live rather than theoretical.

Gate: the `Devirt` probe (`List.foldr (::) []`, `(::)` as a value) reports
`devirtKernel=42` with `shape=0 cnumber=0 emission=0 arity=0` — identical
behaviour through the generalized guards, which is the "moves one row between
tables and changes nothing" property this wave needed.

## Wave 2 — Scheduler

`Scheduler.succeed` and `fail` registered at `DevirtAt 1
(ShapeNoUnboxedScalarAt [ 0, -1 ])` — 87 of the 157 sites.

Purity re-confirmed first, as §3 requires, because devirt promotes the row from
inert to load-bearing: `taskSucceed` is `allocTask(Task_Succeed, value, nil,
nil, nil)` (Scheduler.cpp:123-126) and `taskFail` the same with `Task_Fail`
(:139-142) — plain allocations that touch no scheduler state, enqueue nothing
and register nothing globally. **The exposure is not new in kind**: `Task.succeed`
is an eta-free alias, so ordinary written-out calls already reach this row today;
devirt widens an existing exposure rather than creating one.

Guard rationale: the sole export is `(HPtr) -> HPtr` with no typed variants
(KernelExports.h), so an imprecise site deriving an unboxed scalar would
register a colliding `(i64) -> ptr` declaration — the cons hazard exactly.

## Wave 3 — the scalar batch, and the boundary it ran into

Registered on rows that ALREADY EXIST (18 sites): `String.length`
`DevirtAt 1 [0]` (its result is legitimately an unboxed `i64` — guarding it
would decline every site), `String.toLower` / `String.trim` `DevirtAt 1 [0,-1]`,
`Utils.equal` `DevirtAt 2 [-1]` (suffix-selecting: unboxed ARGUMENTS are what
`equal_Int`/`_Float` exist for, so only the always-`HPtr` result is guarded),
`Utils.append` `DevirtAt 2 [0,1,-1]`.

**The remaining five were initially DEFERRED, then sanctioned and done.** The
plan's assumption that a row-less kernel could "register as safe-but-unoptimized"
is REFUTED — adding a row is never a local act:

Adding a row is not a local act. Measured:

- an `unaudited` placeholder is not inert — `kernelCallCost` answers **6** for an
  unlisted kernel but `costClass unaudited` is `CHof`, cost **20**, so a stub
  would silently suppress inlining of that kernel everywhere;
- an honest row is not inert either. `Basics.not` was audited properly
  (`BasicsExports.cpp` → `Basics.cpp:165-167 return !a`; `ExportHelpers.hpp:80-82`
  shows `elmTrue`/`elmFalse` are embedded HPointer constants, so nothing is
  allocated) and the row is correct — but adding it grew `gcLeafEligible`
  (kernel-opt-08 stamping), extended the borrow shim via `params`, and changed
  the table size, tripping three pinned tests in `KernelFactsTest`. All three
  changes are RIGHT, and all three belong to subsystems this plan did not
  measure.

**This is the cost of the consolidation §1 argued for**: a `KernelFacts` row is
read by five consumers (devirt, inline cost, gc-leaf stamping, the borrow shim,
the MLIR `eco.cse_safe` stamp), so you cannot add one for a single axis.
Registering a row-less kernel for devirt is really "audit this kernel across all
five axes" — and the pins that stopped it were doing exactly their job.

Once sanctioned, all five were audited end-to-end and added, with their pins
updated deliberately rather than silently:

| kernel | audit | devirt |
|---|---|---|
| `Basics.not` | `!a`, returns EMBEDDED True/False constants ⇒ allocates NOTHING (`GcNone`) | `DevirtAt 1 [0,-1]` |
| `Basics.add` | boxed root allocates one box via `boxInt`/`boxFloat` ⇒ `GcFixed 1`; one row covers all three exports since `lookupSymbol` strips suffixes | `DevirtAt 2 ShapeAny` — typed variants make unboxed positions CORRECT |
| `Basics.round` | sole export `int64_t (double)`; no Elm heap value touched ⇒ `GcNone` | `DevirtAt 1 ShapeAny` — unboxed is REQUIRED, a guard would decline everything |
| `String.fromList` | two-pass, one exact-size allocation ⇒ `GcUnbounded`; `cppAlloc` left conservative because the UTF-16 branch was not read end-to-end | `DevirtAt 1 [0,-1]` |
| `Json.wrap` | `POwned` + `resultAliases [0]` — the ENC_BOOL/ENC_STRING branches STORE the argument and the final branch returns it BY IDENTITY; grep over the whole body: zero `eco_apply`, zero statics | `DevirtAt 1 [-1]` — suffix-selecting, so only the always-`HPtr` result is guarded |

Three pinned tests updated with their reasoning: `gcLeafEligible` gains
`Basics.not` and `Basics.round` (both genuinely allocate nothing), the borrow
shim gains all five (listed separately as `wave3BorrowAdditions` so
kernel-opt-07's original inertness claim stays legible), and the table is 57 rows.

## Follow-up: the cost axis learns to say "unaudited"

The `unaudited`-placeholder finding above turned out to be a live defect in its
own right, not just an obstacle. Measured: **no row in the table declared the HOF
bit explicitly**, so every member of `CHof` was there by DEFAULT — including
`JsArray.length`, `String.trim` and `Basics.tan`, which plainly do not re-enter
Elm and were nonetheless priced at `kernelCostHof` = 20 while a kernel with no
row at all cost 6.

Lowering `CHof` to 6 would have been the wrong fix: it would paper over the false
positives while mispricing the true ones (`List.map2`, `JsArray.foldl`,
`String.all` really are expensive to inline around). The defect is the
conflation, so `callsBackIntoElm : Bool` became `callsBack : HofAxis` —
`HofUnknown | HofNo | HofYes` — read differently by different consumers:

- **safety** (`canTriggerGC`, the `cseSafe` implication) reads unknown as
  "might", via `mayCallBackIntoElm`: conservative, unchanged;
- **cost** (`costClass`) returns a new `CUnknown` for an unaudited row, which
  `kernelCallCost` prices at the same centralized `unknownCost` as a missing row.
  Only `HofYes` now reaches `CHof`.

Nine genuine higher-order kernels were given `callsBack = HofYes` explicitly with
body evidence (`List.map2`/`sortBy`/`sortWith`, `JsArray.map`/`foldl`/`foldr`/
`initialize`, `String.all`, `Bytes.decode`) so they keep their real price. The
remaining unaudited rows drop from a cost they never justified to the cost of
not knowing — which mirrors `params = []` for the borrow axis: a row says what it
knows, and silence is not an assertion.

## Coverage and gates

| | sites | status |
|---|---|---|
| `Scheduler.succeed`/`fail` | 87 | registered |
| `String.length`/`toLower`/`trim`, `Utils.equal`/`append` | 18 | registered |
| `Basics.not`/`add`/`round`, `Json.wrap`, `String.fromList` | 52 | registered, after a full `KernelFacts` audit each |

**All 157 sites registered** across 13 kernels. Gates: `--target full`
1685/1685; elm-tests 13,157 passed / same 12 pre-existing; `KernelFactsTest` 7/7
including the new `devirtErrors` checks and the three deliberately-updated pins.
Benchmark row recorded separately in `benchmarks/lss-opt.md`.

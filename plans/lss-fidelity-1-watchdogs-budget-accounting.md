# LSS Fidelity 1 — Watchdogs, Budget Demotion, and ⊤-Accounting

**Status: COMPLETE (2026-08-18).** All phases (A watchdogs both engines, B1/B2/B3
μ-tie now **default-on**, C ⊤-accounting — measured then removed) are landed, and
every gate in §5 is closed with evidence recorded in **§7**: elm-tests 13,118/12
pre-existing, E2E 1,675/1,675 twice, both bootstrap fixed points, watchdog
output-invisibility proven byte-identical on both engines, the native poly-rec
repro erroring cleanly in seconds, and the F-2A sweep filed. Originally PLAN
2026-08-17; revised 2026-08-18 (repro found, crash layer dropped).
First of three plans implementing the gap register of
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md` (§7/§8). This plan
covers, in the mapping doc's suggested order:

- **GAP-8** — the missing poly-rec/blowup watchdogs (`ECO_SPEC_TYPE_NODE_LIMIT`,
  `ECO_SPEC_BREADTH_LIMIT`), the substitute for the termination theorem (Thm 4.1/5.1)
  Eco does not have. **Not insurance:** polymorphic recursion is expressible in legal
  Elm today through annotated mutual cycles, and the native pipeline hangs on it —
  §1.1's repro. The watchdog is the fix. Precondition for GAP-3.
- **GAP-3** — demoting `maxSpecsPerGlobal` from *terminator of the qualification
  spiral* to *pure fan-out policy*, by μ-tying the spiral's self-similar member family
  (the id-space image of the paper's `μa.{ℓ[α↦a]}`).
- **GAP-9 (instrumentation half)** — counters for the two currently-invisible ⊤
  sources: `poisonBoth` at let boundaries and the local-multi member-injection bypass.
  (The per-use-separation repair itself is plan 3's ride-along, sized by these
  counters.)
- The §10 bookkeeping items that belong with accounting work.

Series: this file → `lss-fidelity-2-standalone-member-grounding.md` (GAP-1) →
`lss-fidelity-3-signature-flow-completion.md` (GAP-2 + re-census + GAP-4/5/6/7 +
GAP-9's repair half).

Aims served (mapping doc §0): aim 2 directly (budget as policy, not crutch), aim 1's
accounting criterion ("every ⊤ has a counter"), aim 3 (the paper does not widen).

References verified against HEAD 2026-08-17/18. Line numbers are anchors, not
contracts — locate by function name if drifted.

---

## 1. Phase A — GAP-8 watchdogs

### 1.1 The hang is reachable today (verified 2026-08-18 — the motivating repro)

The recorded decision this phase corrects (`plans/monomorphization-plan.md` §3, which
now carries a dated correction note): *"Elm uses Hindley-Milner type inference which
does not support polymorphic recursion… If code type-checks, recursive calls are
always at the same type."* Empirically **half-true**:

- **Self-recursion: correctly rejected.** An annotated def's own annotation is NOT
  used as a scheme for its own recursive reference — `depth` calling itself at
  `Nested (List a)` gets a clean TYPE MISMATCH.
- **Mutual recursion: admitted.** Each member of an annotated cycle sees the *other*
  members' annotations as generalized schemes — the classic HM-with-signatures
  loophole, expressible in legal Elm.

The repro fixture. **Keep it OUT of `test/elm/src/`** — everything there is compiled
by the E2E suite expecting success, and this program hangs the shipping compiler:

```elm
module Main exposing (main)

type Nested a
    = Nil
    | Deeper a (Nested (List a))

depth : Nested a -> Int
depth n =
    case n of
        Nil ->
            0

        Deeper _ rest ->
            1 + helper rest        -- rest : Nested (List a)

helper : Nested (List a) -> Int
helper n =
    depth n                        -- depth instantiated at (List a)

main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Debug.log "depth" (String.fromInt (depth (Deeper 1 Nil))) |> always Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

Observed 2026-08-18 (`build/compiler/build-kernel/bin/eco`, **default config**:
solver engine, all-keyed LSS, `maxSpecsPerGlobal = 64` live):

- `eco make src/Main.elm --output=main.js` (JS target — no monomorphizer): compiles
  in ~1 s, artifact loads and runs.
- `eco make src/Main.elm --output=main.mlir` (native pipeline): prints
  `Success! Compiled 1 module.` — the front end is *done* — then the monomorphizer
  chases the demand chain `Nested Int → Nested (List Int) → Nested (List (List Int))
  → …` forever. Killed by `timeout 60` (exit 124), RSS ≈ 310 MB and monotonically
  climbing, no output produced.

So the watchdogs are not defense against a hypothetical front-end regression (the
mapping doc's GAP-8 framing understates this — §4 item 6): they fix a **live
non-termination on legal source in the default configuration**.

### 1.2 Why there is no soft fallback here — the dimension argument

LSS already has the right soft fallback, and this plan does not touch it: `LTop` is a
genuine ⊤ for the **lambda-set dimension** — every set lowers to the generic closure
pipeline, and LSS_005 makes widening behavior-invisible. The budget
(`maxSpecsPerGlobal`), `maxSetSize`, and kernel poison stay soft.

No ⊤ exists in the **type dimension**. Types pick heap layout and ABI;
MONO_020/021/024 ("types never widen") is an invariant precisely because widening a
type changes representation out from under already-compiled callers. Concretely: the
past-budget path widens only the SET component of a key (`Intern.widenSets`) — the
type component stays concrete, so `Nested (List^k Int)` mints a fresh spec at every
`k` regardless of budget, which is exactly what §1.1 demonstrates (it hangs *with*
the budget active). A type-dimension soft fallback would mean a uniform boxed
representation plus a second calling convention at every affected site — an
architecture change contradicting whole-program monomorphization, not a knob. The
menu in this dimension is: hang/OOM (today), or a bounded loud error (this phase).

Rejecting the program at typecheck instead would be the wrong layer: the JS target
legitimately compiles it (upstream Elm semantics), so a front-end rejection breaks
Elm compatibility over a backend-only limitation. The monomorphizer errors, and the
message names the cycle.

Precedent, house and industry: this project already caps every argued-but-unproven
fixpoint loudly — `maxJoinRounds = 100` on the LSS_010 flush (capped even though join
monotonicity IS proven), `maxSaturationPasses = 5` (MONO_029). The spec worklist is
the one fixpoint in the monomorphizer with no cap. Rust — a monomorphizing compiler
with identical exposure — ships `recursion_limit` as a hard error with a
user-raisable knob; GHC caps type-family reduction depth the same way. No compiler
soft-falls-back on this class, including ones that *have* a uniform representation
available.

### 1.3 What exists and what is missing

The solver drain (`Compiler/MonoSolver/Monomorphize.elm`, `drain`, :366-424) has
exactly one cap: `maxJoinRounds = 100` for LSS_010 flush rounds — a backstop for
*join oscillation*, not a terminator for *spec growth*. Nothing bounds:

- the number of specs created for one global (breadth — `List.foldl` had 1,939 specs
  on the Aug-4 census; §1.1's cycle grows two globals without bound);
- the size of a spec's demanded type (depth — the poly-rec chain grows the type each
  round).

The subst engine (`Compiler/Monomorphize/Specialize.elm`) has no limits of any kind.
The original watchdog design (Aug 4 2026, `ECO_SPEC_TYPE_NODE_LIMIT` 400k,
`ECO_SPEC_BREADTH_LIMIT` 50k, "clean use-site-annotating errors") survives only in
session memory — its plan file `plans/mono-perf-and-watchdogs.md` never existed in
this checkout. This phase re-materializes and lands it.

### 1.4 Design — counting in Registry, enforcement on each engine's error channel

> **REVISED 2026-08-18.** An earlier draft backstopped the subst engine with
> `Utils.Crash` ceilings inside Registry. Dropped: a watchdog trip is a
> designed-for program/resource condition, not a violated compiler invariant —
> crash-style presentation misclassifies it as a compiler bug, bypasses normal error
> rendering and exit codes, and is untestable. Both engines have a clean error
> channel reachable with contained changes, so the crash layer bought nothing.

**Registry — counting only.** `Registry.getOrCreateSpecId` / `getOrCreateSpecIdKeyed`
(`Compiler/Monomorphize/Registry.elm:77-162`) are the only spec-creation points in
either engine. Add to `SpecializationRegistry`:

```elm
type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Mono.SpecKeyMap
    , reverseMapping : Array (Maybe ( Global, MonoType ))
    , countByGlobal : Dict String Int   -- NEW: CREATED specs per comparable global
    }
```

- Maintain `countByGlobal` on the `CreatedNew` / miss branches only (one
  `Dict.update` per *created* spec — never on the probe/hit paths).
- Construction sites to update (find all with `grep -rn "reverseMapping ="
  compiler/src`): `Registry.emptyRegistry`, the registry rebuild in the solver's
  graph assembly (`MonoSolver/Monomorphize.elm` ~:1044) and the subst engine's
  (`Monomorphize/Monomorphize.elm:266`). The two assembly sites rebuild a registry
  literal for the output graph — pass `Dict.empty` there (the output registry is
  post-hoc; counts are a during-run concern).
- **No ceilings, no `Utils.Crash`, no crash constants.** Enforcement lives in the
  engines.

**Solver — enqueue-time checks.** In `Engine.enqueueSpec` and
`Engine.enqueueSpecKeyed` (`Compiler/MonoSolver/Engine.elm:781-1030`), after the
registry probe, on the created path (`created = reg1.nextId > s.registry.nextId` —
the detection idiom `enqueueSpecKeyed` already uses at :992):

```elm
-- Engine.elm, new:
checkSpecWatchdogs : Mono.Global -> Mono.MonoType -> SpecializationRegistry -> S -> Maybe Failure
-- breadth: Dict.get gkey reg.countByGlobal > s.env.limits.specBreadth
-- depth:   not (Mono.typeNodesWithin s.env.limits.specTypeNodes monoType)
```

A tripped check fails the Step with a **new `Failure` variant**:

```elm
type Failure
    = Unsupported String
    | UnifyMismatch String
    | EngineBug String
    | LimitExceeded String      -- NEW: resource watchdog, not a compiler bug
```

Blast radius: `renderFailure` (`MonoSolver/Monomorphize.elm:1236-1246`) gains one arm
(no "compiler bug" framing); grep for other exhaustive `Failure` matches (expected:
only `renderFailure`). Enqueue-time placement is preferred in this engine because the
message can name the enclosing context (`s.currentGlobal` — "while specializing X…").

**Subst — drain-level checks.** `processWorklistPure`
(`Compiler/Monomorphize/Monomorphize.elm:295-302`) becomes

```elm
processWorklistPure : Config.SpecLimits -> MonoState -> Result String MonoState
```

Its single caller (`monomorphizeFromEntryWith`, :134) already returns
`Result String Mono.MonoGraph` — plumb the `Err` through. After each processed work
item, validate only the specs *created during that item*: fold
`reverseMapping[prevNextId .. nextId)` (capture `prevNextId` before the item); per new
entry `(global, monoType)` check `countByGlobal` against the breadth limit and
`typeNodesWithin` against the node limit. Same message text as the solver (share the
formatter). Per-item granularity is sufficient: the pathology is growth *across*
items — each spec enqueues a bigger-typed successor — so catching it one item late
changes nothing. The limits reach the subst driver as a new `Config.SpecLimits`
parameter on `monomorphize` (grep its callers — the Builder/Generate layer already
holds the config; tests pass `Config.defaultLimits`).

**Shared helper.** `Mono.typeNodesWithin : Int -> MonoType -> Bool` — a new
early-exit node counter in `Compiler/AST/Monomorphized.elm` (structural walk
decrementing a budget, `False` the moment it hits zero; every constructor counts as
1 node). K6 hash-consed sharing does not shrink the *logical* count — the walk is
O(min(limit, size)) and only pathological types approach the limit.

**Explicit non-goal.** An infinite loop *within* one work item (no enqueues) is
caught by neither enforcement point — that class is a compiler bug, not input-driven
growth, and is out of scope here.

### 1.5 Config plumbing

- `Compiler/Eco/Config.elm`: add to `MonoConfig` (:154-159):

```elm
, limits : SpecLimits

type alias SpecLimits =
    { specTypeNodes : Int   -- default 400000
    , specBreadth : Int     -- default 50000
    }

defaultLimits : SpecLimits
```

  JSON-decodable (`optionalField` pattern as `lssDecoder`, :581-594), with `0`
  meaning "disabled" (checks skipped).
- **Excluded from `Config.hash`** (:800-830): the watchdogs never change the output
  of a *passing* compile — same class as `report`/`validate`/`diffDump`. State this
  in the field docstring; it is the invariant that makes defaults freely tunable.
- `Builder/Eco/Config.elm`: env overrides `ECO_SPEC_TYPE_NODE_LIMIT` /
  `ECO_SPEC_BREADTH_LIMIT` (integer parse, warn-and-ignore on garbage), following the
  `ECO_MONO_LSS_MAX_SPECS` pattern (:1162-1177).
- `Engine.Env` (`Engine.elm:335-344`): add `limits : Config.SpecLimits` (Env is a
  9-field ordinary record — S itself stays at 32 fields; do NOT add anything to S).
  Populate in `initState` (`MonoSolver/Monomorphize.elm:235+`).

### 1.6 Error message contract

The message must let a user act without reading compiler source, and both engines
emit the same text (the solver prefixes the enclosing-spec context). Format:

```
specialization budget exceeded for Main.depth
  50000 specializations created (limit 50000, ECO_SPEC_BREADTH_LIMIT)
  This usually means polymorphic recursion reached the monomorphizer — commonly an
  ANNOTATED, MUTUALLY RECURSIVE cycle whose members call each other at growing type
  instantiations — or unbounded type growth. Break the chain with a concrete type
  annotation at the recursive call site, or raise the limit if the program is
  legitimately this large.
  Inspect with ECO_MONO_LSS_REPORT=1 (see "top specs/global").
```

The depth variant names the global whose *key* overflowed and prints the node count.
Both include the env var by name. We can name the global precisely; true
source-region attribution would need demand provenance we don't track (explicit
non-goal).

### 1.7 Tests and gates

- Unit (`tests/TestLogic/Monomorphize/SpecWatchdogTest.elm`): `typeNodesWithin`
  boundary cases (exact limit, limit+1, deep nesting, wide records); registry
  `countByGlobal` maintenance on create-vs-hit.
- **Watchdog repro test** — replaces this plan's earlier "E2E negative test: none —
  Elm HM cannot express poly-rec", which §1.1 falsified. Drive the §1.1 cycle
  through **both engines** with tiny limits
  (`{ specBreadth = 8, specTypeNodes = 200 }`) and assert failure + message content:
  - solver: engine-level test constructing `S` with the limits and the two-def
    annotated `TOpt.Cycle` (follow the harness of existing
    `tests/TestLogic/Monomorphize/` suites; build the cycle nodes directly if the
    harness has no source-compile path), asserting `LimitExceeded` with the global
    name and env var in the message;
  - subst: `monomorphize` with the limits parameter, asserting `Err` with the same
    text.
- Fixture source checked in at `tests/fixtures/polyrec-mutual/Main.elm` (**not**
  under `test/elm/src/` — §1.1 warning) for the manual native check:
  `timeout 60 eco make src/Main.elm --output=main.mlir` — today exit 124 (hang);
  post-A, a clean error. Note: at DEFAULT limits the repro trips breadth only after
  ~50k worklist rounds — bounded, but possibly minutes of spinning — which is why
  the automated tests always use small overrides.
- Gates: `cmake --build build --target full` green (run ONCE, tee to
  `/tmp/test_output.txt`); self-compile completes with default limits and **zero**
  watchdog trips; `ECO_MONO_LSS=0` build byte-identical (counters/config are
  output-invisible); an `ECO_MONO_ENGINE=subst` self-compile leg still byte-exact
  (the solver-vs-subst self-host gate); mono wall delta ≈ 0 (counting is
  per-created-spec).

---

## 2. Phase B — GAP-3: μ-tie the qualification spiral, demote the budget

### 2.1 The spiral, precisely

Fix B (LSS_017) qualifies translation-phase lambda mints: spec `S` of a keyed-routed
global mints member `Q(L,S)` = interned `l|<raw L>|<S>`
(`Engine.lambdaInstanceMemberId`, `Engine.elm:259-297`). Qualified ids flow into
annotations, annotations into keyed spec keys, keys into new specs:

```
S1 mints Q(L,S1) → callee demand embeds Q(L,S1) → spec S2 → S2 re-mints L as Q(L,S2)
→ demand embeds Q(L,S2) → spec S3 → …
```

Verified 2026-08-16 (mapping doc GAP-3): the **only** terminator of this spiral is the
M4 budget (`maxSpecsPerGlobal = 64`, `enqueueSpecKeyed`, `Engine.elm:960-1030`) —
past it, keys widen and the fan-out stops. `maxJoinRounds` is a crash backstop, not a
terminator. So the budget is load-bearing for termination, violating aim 2, and
spiral-burned budget also crowds out legitimate fan-out (`widenedByBudget = 50,778`
on the shipping census — composition unknown until B1 below). Note the contrast with
§1.2: the spiral lives in the SET dimension, where widening IS a sound terminator —
the μ-tie is about reclaiming *precision and policy freedom*, not about soundness.

### 2.2 The μ-tie

The paper's internalization emits `μa.{ℓ[α↦a]}` when a set is self-similar (146:11).
The id-space image: when translating spec `S` whose **own demand already contains a
qualified member of raw lambda `L`**, the value being minted *is* the value that
arrived in the demand — one recursive family. Minting `Q(L,S)` fresh creates a new
identity whose only effect is to spawn the next family member. Instead, **tie**: reuse
the qualified id already present in the demand. Then the next callee demand equals the
current one, the registry key hits, and the family closes at its second member.

**Detection (per work item, memoized).** In `processItem`
(`MonoSolver/Monomorphize.elm:436-486`), where `itemAux.currentSpecId` is set, also
build:

```elm
-- ItemAux (Engine.elm:428-434) gains one field (6 fields — ordinary record):
, demandQualified : Dict Int Int   -- raw lambda id -> SMALLEST qualified member id present in this spec's stored demand
```

from the registry's stored `monoType` for `specId`, via a new
`Mono.collectAnnoMembers : MonoType -> List Int` (fold over every `MFunction`
annotation's `LSet` members), filtering through the new reverse table (2.3). Choosing
the smallest id per raw makes the canonical family id deterministic. Build only when
`s.env.lss.enabled` and the item routes keyed (same predicate as `enqueueSpec`,
`Engine.elm:788-794`); otherwise leave `Dict.empty`.

**Tie (at the mint).** In `lambdaInstanceMemberId` (`Engine.elm:259-297`), on the
routed path with `currentSpecId = Just specId`, before interning `Q(L,S)`:

```elm
case Dict.get raw s0.itemAux.demandQualified of
    Just tiedId ->
        -- μ-tie: reuse the family id; census-bump; record as blocked (2.4).
        Ok ( tiedId, bumpMuTied (blockMember tiedId s0) )
    Nothing ->
        -- today's path: intern Q(L,S); ALSO record it in lambdaQualified (2.3)
```

Gated by a new knob `lss.muTie : Bool` (see 2.6); when the flag is off, still bump the
census counter on detection but mint as today (B1 measures the population before any
behavior changes).

### 2.3 New tables (32-slot discipline)

`S` is at the 32-field cap — all new state goes into existing sub-records:

- `Engine.LssMemberTable` (:162-165) gains two fields (4 total):

```elm
, lambdaQualified : Dict Int ( Int, Int )  -- qualified mid -> (raw lambda id, minting SpecId); written at the Q(L,S) intern
, muTied : Dict Int ()                     -- member ids that were ever the target of a μ-tie (the AbiCloning block set)
```

- `Engine.LssStats` is near-cap (27 fields; the substrate memory records the cap
  biting it). Add **one** nested record for the whole fidelity series:

```elm
, fidelity : FidelityStats

type alias FidelityStats =
    { muTied : Int            -- Phase B: mints that hit demandQualified (tied when flag on; eligible-count when off)
    , widenedByLet : Int      -- Phase C: poisonBoth invocations (let-boundary ⊤, GAP-9a)
    , localMultiBypass : Int  -- Phase C: local-multi args skipping member injection (GAP-9b)
    }
```

  (Plans 2 and 3 add their counters here, not to `LssStats` directly.)
- Render in `renderLssReport` (`MonoSolver/Monomorphize.elm:208-228`): one line,
  `"fidelity: muTied=… widenedByLet=… localMultiBypass=…"`.

### 2.4 Soundness: tied members must not stamp

A tied id names **two or more instances** (the ancestor spec's mint and every tied
descendant's). These are same-source-lambda, same-layout, but translated under
*different demands* — their bodies' inner fast-dispatch decisions can differ, which is
exactly the §11.6/E11 representative-hijack precondition LSS_017 exists to prevent.
Rep-stamping a tied member is therefore forbidden; declining it is sound (generic
dispatch — the LSS_005 lattice).

AbiCloning already has the machinery: a member with `blocked = True` never stamps and
its buckets are dropped (`AbiCloning.elm:174-192, ~290`; census `declinedBlocked`).
Wire the block set through:

1. `Mono.MonoGraph` gains `lssBlockedMembers : Dict Int ()`. Construction sites (find
   with `grep -rn "lssMemberOrigins =" compiler/src`): solver assembly
   (`MonoSolver/Monomorphize.elm:1053` — from `s.lssMemberTable.muTied`), subst
   assembly (`Monomorphize/Monomorphize.elm:275` — `Dict.empty`), `Prune.elm:248`
   (copy through), `MonoInlineSimplify.elm:812` (destructure + carry).
2. `abiCloningPass` (`AbiCloning.elm:531`): when building the member index, force
   `blocked = True` for every id in `record.lssBlockedMembers` (union with the
   existing wrapper-adoption blocking rule).

Note the LSS_008 interplay: tied instances **keep** their `lssMember` stamp (a closure
counted for no member while its annotation names one re-establishes false uniqueness —
the LSS_008 miscompile). Blocking at the index, not stripping at the instance, is the
only sound shape.

### 2.5 Termination argument (record in the code doc)

With the tie: along any demand chain, the first mint of raw `L` under spec `S1`
creates `Q(L,S1)`; every deeper spec whose demand carries `Q(L,S1)` re-mints `L` as
`Q(L,S1)` itself, so the set of qualified ids per (raw lambda × demand chain) is
finite (≤ the chain's distinct *entry* demands, which no longer grow by
qualification). Keyed fan-out then terminates on the same argument as type
monomorphization (finite demand lattice), independent of `maxSpecsPerGlobal`. The
budget's remaining role is fan-out *policy* (compile-time/binary-size control) — aim 2
discharged. LSS_005 is preserved: tying changes annotations, spec counts, and dispatch
tiers (tied members decline), never observable behavior.

### 2.6 Flag, hash, rollout

- `Config.LssConfig` gains `muTie : Bool` (10th field), default `False` at B1,
  flipped `True` at B3. JSON `optionalField "muTie"`; env `ECO_MONO_LSS_MU_TIE=1|0`;
  hash token `lssMU=1` **when it differs from the default** (follow the
  `lssS`/`lssB` pattern, `Config.elm:819-830`) — the tie is artifact-affecting under
  keyed routing (member ids → keys → fan-out).
- **B1 (census, flag off):** land detection + counters + tables + report line. Run the
  self-compile census (`ECO_MONO_LSS_REPORT=1`; use the stage-1 JS fast-census loop —
  see `plans/lss-set-write-substrate.md` Phase 1 methodology — before any native
  rebuild). Deliverable: `fidelity.muTied` (eligible population) and its share of
  `widenedByBudget`.
- **B2 (tie, flag on locally):** full gate battery — `--target full` E2E; the
  SIGSEGV-class repro workload from the fork plan (§7) still green; self-compile
  bootstrap fixed point (two-binary/frozen-corpus protocol — byte-identity of
  `eco-compiler.mlir` across a self-compile round-trip at the SAME flag setting);
  `unqualifiedLambdaMints` still 0; `multiInstanceGroups` delta explained by tied
  members only; census: `widenedByBudget` expected to DROP materially, `declinedBlocked`
  rises by the tied population. Purge `build/test/*/eco-stuff` between E2E legs; never
  run the two suites concurrently (cache race).
- **B3 (default flip + budget experiment):** flip `muTie = True` in `defaultLss`;
  re-run battery. THEN re-run the F-2A budget sweep (N = 64 → 256 → 1024) as a
  *measurement*, not a default change: with the spiral gone, the sweep isolates
  legitimate fan-out cost (baseline: N=1024 was +4.36% binary, ~+6% mono wall,
  licence pool 58→143). File the sweep results in this plan; any default-budget
  change is a separate decision with those numbers in hand.

### 2.7 Invariants delta

Add to `design_docs/invariants.csv` (LSS block; LSS_012 remains skipped):

- **LSS_018** (Monomorphization;LambdaSets;implemented): Under `lss.muTie`, a
  translation-phase lambda mint whose enclosing spec's stored demand already carries a
  qualified member of the same raw lambda reuses that member id (μ-tie; canonical =
  smallest such id), records it in `lssMemberTable.muTied`, and every μ-tied id is
  exported via `MonoGraph.lssBlockedMembers` and force-blocked in AbiCloning's member
  index — tied members never rep-stamp (multi-demand instances are behaviorally
  divergent; the §11.6 hijack class). Termination of the specs→qualified-members→keys
  spiral no longer depends on `maxSpecsPerGlobal`.
- **MONO_030** (Monomorphization;Watchdogs;implemented): Spec creation is guarded by
  breadth (`ECO_SPEC_BREADTH_LIMIT`, default 50000 per global) and key-size
  (`ECO_SPEC_TYPE_NODE_LIMIT`, default 400000 logical nodes) watchdogs, enforced on
  each engine's own error channel — enqueue-time `LimitExceeded` failures in the
  solver, per-item drain checks (`processWorklistPure → Result String`) in the subst
  engine; no crash paths. `Registry.countByGlobal` counts created specs for both.
  Load-bearing, not defensive: polymorphic recursion IS expressible in legal Elm
  through annotated mutual cycles (verified 2026-08-18; see the correction note in
  `plans/monomorphization-plan.md` §3) and the type dimension has no ⊤ fallback
  (MONO_020/021/024 — set-widening does not bound type-keyed growth), so without the
  watchdog the monomorphizer diverges on legal source. The substitute for the paper's
  Thm 4.1/5.1 termination guarantees (mapping doc GAP-8) and the precondition for
  treating the LSS budget as policy (GAP-3). Limits are output-invisible on passing
  compiles and excluded from `Config.hash`.

Amend **LSS_017**'s row: add "termination of the qualification spiral is owned by
LSS_018's μ-tie, not the budget" to its rationale tail.

---

## 3. Phase C — GAP-9 instrumentation (counterless ⊤ sources)

Two v1 policies widen to ⊤ with no census trace (a direct violation of aim 1's
"every ⊤ has a counter"; mapping doc GAP-9):

1. **Let-boundary poison.** `LssInfer.poisonBoth` (`LssInfer.elm:1220-1227`) — called
   from `joinArrowSets` on structural divergence (:1176-1177) and on
   variable-at-either-side (:1185-1187). Verify with grep that `joinArrowSets` is the
   only caller. Bump `fidelity.widenedByLet` once per `poisonBoth` invocation (bump
   inside `poisonBoth` itself, threading `Engine.S` — it already returns a Step).
2. **Local-multi bypass.** `Translate.unifyParamsCollect`'s local-multi arm
   (`Translate.elm:2930-2947`): a local-multi function arg is fresh-instantiated and
   unified with **no** `injectArgLambdaMember` call — "no member, no stamp"
   (:3070). Bump `fidelity.localMultiBypass` in that arm (per call-site arg event).

Both counters land in the Phase B `FidelityStats` record and the report line. Zero
behavior change; lss-off untouched (both sites are inside lss-only flow — verify:
`joinArrowSets` only runs from the inference walk, which is lss-gated at
`signatureFor`; the local-multi arm runs regardless of lss, so gate its bump on
`s.env.lss.enabled` to keep the off path allocation-identical).

**Deliverable:** one fast-census run recording both counters against
`topSiteShapes local=7,361` (the all-keyed baseline, mapping doc §6). These numbers
size plan 3's per-use-separation decision. No repair here.

---

## 4. Bookkeeping ride-alongs (mapping doc §10 + the 2026-08-18 finding)

Cheap, textual, zero-risk — land with Phase C (item 5 is already done):

1. `plans/lss-fork-qualified-members.md` §6.5: budget-widening cite
   `Engine.elm:712-723` → `Engine.elm:876-894` (and note LSS_018 now owns spiral
   termination).
2. `invariants.csv`: annotate LSS_012 as permanently skipped (reserved for the closed
   E3); amend LSS_009's row with its LSS_017-discharge note (fork plan §10 debt).
3. `Unify.elm:757-758`: fix the `≤8 members` comment — the cap is enforced only at
   zonk readback (`Store.elm:1374`); in-store sets may transiently exceed it.
4. This plan supersedes the memory-only watchdog design; when Phase A lands, note in
   the commit message that `plans/mono-perf-and-watchdogs.md` §3 is re-materialized
   here.
5. **DONE 2026-08-18:** `plans/monomorphization-plan.md` §3 ("Polymorphic Recursion —
   Decision: No special handling needed") carries a dated correction note — the
   no-poly-rec claim is false for annotated mutual cycles; it points at §1.1's repro
   and MONO_030.
6. `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md` GAP-8 says "a
   front-end regression admitting poly-rec means a silent hang/OOM" — understated: no
   regression is needed (§1.1). Add a dated amendment to that gap when Phase A lands,
   citing this plan.

---

## 5. Execution order and gate summary

**All steps below are DONE (2026-08-18) — §7 records how each gate was closed.**

| step | contents | flag state | gates |
|---|---|---|---|
| A1 | registry `countByGlobal` + `typeNodesWithin` | n/a | unit tests; `--target full`; lss-off byte-identity |
| A2 | solver `LimitExceeded` checks + config/env plumb | limits active (defaults) | self-compile zero-trip; watchdog repro test (solver); message-content test |
| A3 | subst drain-level checks (`processWorklistPure → Result`) + fixture check-in | limits active | watchdog repro test (subst); `ECO_MONO_ENGINE=subst` self-host leg still byte-exact |
| C1 | fidelity counters + report line + §4 bookkeeping | n/a (census-only) | `--target full`; one fast-census run recorded |
| B1 | μ-tie detection + tables + counter | `muTie=False` | census: eligible population vs `widenedByBudget` |
| B2 | tie active locally | `muTie=True` (local) | full battery: E2E, fork-plan repro, bootstrap fixed point, census deltas |
| B3 | default flip + F-2A re-sweep | `muTie=True` (default) | battery again; sweep results filed; invariants rows landed |

Test-run discipline (CLAUDE.md): run each suite ONCE with
`2>&1 | tee /tmp/test_output.txt`, grep the file for failures; serial suites only;
purge `build/test/*/eco-stuff` between E2E legs.

## 6. Risks

- **Tie meets LSS_010 re-translation:** interning is idempotent and
  `demandQualified` is rebuilt per item from the (joined) stored demand, so a dirty
  re-translation re-ties identically or ties *more* (never less) — monotone, matches
  LSS_010's lattice argument. Test: an LSS_010-style shared-HOF fixture with a
  recursive callback (extend `test/elm/src/LssSharedSpecJoinTest.elm` pattern).
- **Blocked-member dispatch regression:** sites that today (accidentally,
  budget-truncated) stamp a spiral member will decline post-tie. The runtime dispatch
  census (Run-M methodology, `benchmarks/runtime-calls.md`) bounds the cost; expected
  ≈0 (spiral members live in budget-widened territory today, which never stamps
  either).
- **`countByGlobal` growth:** one Dict entry per global with ≥1 spec (~10-20k) —
  negligible.
- **Watchdog false positives on legitimately huge programs:** limits are env-tunable
  and 0-disable; the error message says so. Defaults chosen ≥25× the observed
  self-compile maxima (1,939 breadth; key sizes ~10³).
- **Default-limit trip time on the repro:** breadth 50000 means ~50k worklist rounds
  before the clean error — bounded, but potentially minutes of spinning first. That
  is the accepted trade for defaults that can never false-positive on real programs;
  users who want a snappier tripwire can lower the env var, and the automated tests
  always run with small overrides.

---

## 7. Execution record — **PLAN COMPLETE** (2026-08-18)

Every phase of §5's table is landed and every gate is closed with evidence. This
section is the record; the plan above is unchanged except where a deviation is
noted here.

### 7.1 What landed

| phase | contents | state |
|---|---|---|
| A1 | `Registry.countByGlobal` (create/miss branches only) + `Mono.typeNodesWithin` | landed |
| A2 | solver enqueue-time `LimitExceeded` + `SpecLimits` config/JSON/env (hash-excluded) | landed |
| A3 | subst per-item drain checks (`processWorklistPure → Result String`) + repro fixture | landed |
| C1 | ⊤-accounting counters + report line + §4 bookkeeping | landed, then **removed** after their one-shot census (§7.5) |
| B1 | μ-tie detection, tables, census | landed |
| B2 | tie active, AbiCloning force-block, full battery | landed |
| B3 | **`muTie` flipped DEFAULT-ON**; F-2A sweep re-run | landed (§7.5) |

Invariants: **MONO_030** (watchdogs) and **LSS_018** (μ-tie, `tested`) added;
**LSS_009** and **LSS_017** amended; **LSS_012** annotated as permanently skipped.
Docs: `plans/monomorphization-plan.md` §3 correction note, fork plan §6.5
(stale cite + spiral-ownership), mapping doc GAP-8 amendment.

### 7.2 Deviations from the plan as written

- **Fixture path**: `test/fixtures/polyrec-mutual/` (the repo has no top-level
  `tests/`). Never add it to a compiled suite — under a watchdog-less compiler it
  hangs the build.
- **Test root**: SourceIR fixtures must define `testValue`, not `main` (the
  harness synthesizes `main` around it).
- **Subst signature**: the public `monomorphize` is preserved; limits arrive via a
  `monomorphizeWithLimits` twin, so legacy call sites are untouched.
- **Error rendering (beyond the plan)**: the Builder appends "This is likely a
  compiler bug" to *every* monomorphization error. §1.6's no-bug-framing contract
  therefore required suppressing it for watchdog messages
  (`Exit.elm GenerateMonomorphizationError`, prefix `"specialization "`), and
  globals now render as `Module.name (author/project)` via `Registry.prettyGlobal`
  rather than the raw comparable key.
- **EngineDiff is NOT usable as a gate on this tree** (see §7.3, A1/A3 row).

### 7.3 Gate results

| gate (plan §5 / §1.7) | closed by | evidence |
|---|---|---|
| unit tests | `SpecWatchdogTest` (10 cases) + `MuTieTest` (3 cases) | elm-tests **13,118 passed / 12 failed**, the 12 being the pre-existing known-failing set |
| `--target full` | run at default config, and again after the B3 flip | **1,675 / 1,675 PASSED** both times |
| watchdog repro, solver + subst | poly-rec cycle at tiny limits | both engines fail with the shared message; content asserted |
| self-compile zero-trip at default limits | Runs K/M | no trips |
| native repro | fixture + `ECO_SPEC_BREADTH_LIMIT=50` | clean error in seconds naming `Main.depth (author/project)` / `Main.helper`, no bug-framing (pre-watchdog: infinite hang) |
| **lss-off byte-identity** (A1) | watchdogs-active vs watchdogs-disabled on the 243-module corpus | `lssoffA.mlir` ≡ `lssoffB.mlir`, **byte-identical (cmp)**, 13,330,577 B |
| **subst self-host** (A3) | subst self-compile, both limit settings | completes (exit 0, 13,301,825 B); `substA.mlir` ≡ `substB.mlir`, **byte-identical** |
| mono wall delta ≈ 0 | Run K vs Run J | census removal measured at zero; watchdog cost ≤1–2% mutator (§7.4) |
| fork-plan §7 repro | self-compile under all-globals keying, tie armed | Run M completes, `unqualifiedLambdaMints = 0` |
| **bootstrap fixed point** (B2) | `cmake --build build --target bootstrap` at the shipping default | JS check (stage 4b) **PASSED**; native check (stage 8c) **PASSED** |
| census deltas (B2) | Run M vs Run K | byte-identical MLIR, identical GC counters, `declinedBlocked = 0` (no ties fire here) |
| F-2A sweep (B3) | budgets 64 / 256 / 1024, one binary | §7.5 |

**Why A1/A3 are closed this way.** The plan's wording implies a pre/post
comparison, which is unsatisfiable here: byte-identity across a source change needs
a frozen corpus plus a pre-change binary, and none survives (`--target full` deletes
`bin/eco`; `eco-compiler` was rebuilt). The substitute is *stronger* for the actual
question — because `SpecLimits` is deliberately excluded from `Config.hash`, the same
binary can compile the same corpus with the watchdogs **active** and **disabled**
(`ECO_SPEC_BREADTH_LIMIT=0 ECO_SPEC_TYPE_NODE_LIMIT=0`), which isolates *my* code
rather than the whole diff. Both engines produce byte-identical MLIR, so the
watchdogs cannot alter a passing compile. (`eco-stuff` must be purged between arms —
hash-excluded limits share cache entries, so an unpurged second arm would be
vacuous.)

**EngineDiff was tried first and rejected as a gate.** `ECO_MONO_ENGINE=diff` fails
on this tree for a **pre-existing** reason unrelated to this plan: for ctor nodes the
solver deliberately keeps the arrow-typed *demand* in the registry while subst
overwrites it with the value type (`processItem`'s `nodeSupportsRetranslation`
branch, documented in-code as "found by E9" and present before any edit here), so
the serialized graphs differ at `reg=G.Perform:`. Recorded so the next person does
not re-derive it.

### 7.4 Measurements

Benchmarks are in `benchmarks/lss-opt.md` (Runs J, K, M + the sweep).

- **Cost vs the G/H baseline** (Run K, census removed): true mutator 202.8 → 210.0 s
  (+3.5%), minors +1.8%, promoted 12,784 → 13,464 MiB (+5.3%), majors 12 → 16
  carrying most of the +27 s wall. Attribution: the promoted growth tracks this
  workload's corpus-growth precedent (+30.8 KB of compiler source; cf. Run B
  +8.8 KB → +2.0%, Run I +3.3 KB → +2.8%), i.e. **the dominant cost is the
  implementation being compiled as the workload**, with the executing cost of the
  watchdogs bounded by a ≤1–2% mutator residual. A corpus-controlled A/B is
  impossible without a pre-change binary; that is the attribution floor.
- **Census cost: zero.** Run K ≡ Run J within noise (majors 16 = 16, minors
  1,406 → 1,401, promoted +0.08%).
- **μ-tie cost: unmeasurable.** Run M vs Run K — byte-identical MLIR, GC counters
  identical to the object, wall +0.5% (FLAT), +21.7 MB RSS for the
  `lambdaQualified` table (36,650 entries).
- **⊤-accounting (GAP-9, one-shot):** `widenedByLet = 672`,
  `localMultiBypass = 469` against `topSiteShapes local = 7,361` — minor components
  of the local-⊤ mass. Input to plan 3 Phase H, which now **leans PARK**.
- **Spiral population: empty here, real in general.** `muTied = 0` on the
  self-compile with the mechanism armed (`qualifiedRecorded = 36,650`), so
  `widenedByBudget = 50,904` is legitimate fan-out (`Basics.apR` = 3,223 specs
  tops the table), NOT spiral burn — §2.1's assumption that spiral burn is a
  material share of budget widening is **refuted on this workload**. The mechanism
  is nevertheless proven: `MuTieTest`'s forced spiral fans out to **65** specs
  flag-off (= `maxSpecsPerGlobal` + seed — the budget is the *only* flag-off
  terminator, confirming the fork plan §6.5 hazard) and closes at **2** flag-on.

### 7.5 Decisions taken

1. **Census removed after its one-shot measurement** (user-directed, to isolate
   implementation cost). `FidelityStats` deleted; `poisonBoth` /
   `unifyParamsCollect` reverted to their pre-plan shape, each keeping a comment
   citing its measured figure; the μ-tie demand scan and `lambdaQualified`
   recording gated on `lss.muTie`. The report's `muTie:` line now derives
   tied/qualified counts free from table sizes. Re-instrumentation recipe: re-add
   the two bumps plus an eligible-scan gate on `lss.report`.
2. **B3: `muTie` flipped DEFAULT-ON.** Evidence: behavior-neutral where the spiral
   is absent (byte-identical MLIR on the self-compile), unmeasurable cost, and
   proven effective where it is present (65 → 2 specs). This is what discharges
   **aim 2** — `maxSpecsPerGlobal` is now fan-out policy, not the terminator of
   record. Disabling it costs a hash token (`lssMU=0`).
3. **F-2A sweep re-run** with the spiral tied, one binary, budgets 64 / 256 / 1024
   (`benchmarks/lss-opt.md` Run N; `out.mlir` size is the code-size proxy — the
   original F-2A quoted native binary size, which would need a Stage-5/6 chain per
   budget for the same signal). Result: byBudget widening 50,904 → 29,185 → 13,935
   for +3.2% → +6.8% code size, wall FLAT (+1.0% at 16× budget), majors 16 in all
   three legs. Versus the historical F-2A (+4.36% binary, ~+6% mono wall) the code
   growth is comparable but **the wall cost has vanished** — the substrate work of
   Runs C/E/G absorbed it. Even N=1024 leaves 13,935 widening events, so no budget
   in this range fully satisfies demand. The sweep is a *measurement*, not a default
   change: **`maxSpecsPerGlobal` stays at 64**, and the curve is the pricing sheet
   for anyone who wants more fan-out.

### 7.6 Handed onward

- **Plan 3 Phase H** (per-use let-set separation): sized by §7.4's counters —
  leans PARK.
- **Plan 2/3**: the fidelity census sub-record is gone; those plans should add
  counters under `lss.report` gating rather than unconditionally.
- **Not in scope, recorded for whoever needs it**: EngineDiff's ctor-registry
  divergence (§7.3) is a live, pre-existing engine inconsistency.

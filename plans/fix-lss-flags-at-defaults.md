# Fix the LSS flags at their defaults and remove them

**Status: IMPLEMENTED 2026-09-18** (log from §9). Remove 31 of the 32 LSS flags,
each fixed at its CURRENT default, so the behaviour it selects becomes
unconditional. `lss.enabled` stays a working flag. No behaviour change is
intended at defaults; the gate is byte-identical emission throughout.

**Outcome: all six batches landed, every gate green.** Emission is
byte-identical against the pre-removal baseline across 633 workloads at every
batch, with a zero-line diff on the per-workload LSS census; elm-tests held the
standing 12-failure set throughout; E2E was 1,727/1,727 at every batch; and both
mandated bootstraps reached both of their fixed points. `LssConfig` is 27 -> 7
fields, `ECO_MONO_LSS*` 33 -> 8, `compiler/src` -2,529 lines. The costs that
were larger than §3 priced are §11 and §14; read those before relying on the
unit suite to catch an LSS regression.

## §1 WHY — flag boundaries are the obstacle, not the flags

Every flag is a boundary that the code on both sides must respect. Two mechanisms
that each walk the same structure cannot share a traversal while each must remain
independently switchable, because the switch has to be observable per mechanism.
The flags therefore force a shape on the code that has nothing to do with what the
code is for.

The settle chain is the clearest instance. `Monomorphize.elm:188-191` reads:

```elm
settleVarSuccessors
    (settleVarLambda
        (settleVarSuccessors (settleCtorRows (settleVarCtorRows sDrained)))
    )
```

**Five pass invocations over the registry**, each opening with its own
`if not (s.env.lss.enabled && s.env.lss.<flag>) then s`. `settleVarSuccessors`
runs TWICE because the ordering constraint between it and `settleVarLambda` is
expressed by re-running a whole pass rather than by interleaving — which is what
you do when the passes must stay separately switchable. Fixed at their defaults
these are five traversals that could be one, and the ordering could be a statement
inside it rather than a call sequence.

There are **134 flag consumer sites** in `compiler/src` outside `Eco/Config.elm`.
Each is a branch that must stay live, and a merge candidate that cannot merge.

## §2 WHAT — the inventory

### 2.1 Remove: 29 default-ON booleans (delete the flag and the OFF branch)

`stamp.rootFoldDepth`, `stamp.useInjectPap`, `flow.litFacts`, `flow.accessFlow`,
`flow.letOverlay`, `stamp.useInject`, `stamp.papFast`, `stamp.flatPeel`,
`instanceQual` (`stamp.enabled`), `settle.varLambda`, `settle.varCtorRows`,
`settle.varSucc`, `destrAnno`, `rsTop`, `injTotal`, `refPapSpine`, `rootFold`,
`regIdentity`, `papMembers`, `refIdentity`, `arrowSolverRoots`, `arrowIdentity`,
`postSettleDevirt`, `layoutQualMembers`, `sigFlow`, `groundStandalones`, `muTie`,
`devirtFnGlobals`, `keyed`.

The ON path becomes unconditional; the `else` arm and the flag disappear.

### 2.2 Remove: 2 default-OFF (delete the flag and the mechanism)

`flow.connect` and `keyedGlobals` — flipped default-off 2026-09-18 on the solo
census. These are deletions in the shape of
`plans/remove-default-off-lss-flags.md`: the gated code goes with the flag.
`defaultKeyedGlobals` is already `[]`, so its removal takes the field, the env
handler and the `lssKG=` token.

### 2.3 Keep

- **`lss.enabled`** — the one switch that survives, per the brief.
- **The censuses**: `report`, `qCensus`, `arrowCensus`, `stamp.census`. They are
  output-only, they gate no optimization, and removing them would blind the
  benchmark protocol that gates this very work. `report` is MANDATORY in
  `benchmarks/flag-off-lss-loop.md`.
- **The three numeric caps — DECIDED 2026-09-18 (user): they STAY, and they are
  not in scope.** `maxSetSize` (0), `maxSpecsPerGlobal` (0) and
  `stamp.maxInstances` (8) are not flags in this plan's sense. A flag selects
  between two code paths and therefore imposes a boundary; a cap is a policy
  value read at one site and imposes none, so removing them would unlock no
  merge. Two are at `0 = unlimited`, so "fixing at the default" would mean
  deleting the widening code outright and with it the documented backstop for the
  elm-aws-codegen pathological class — `ECO_MONO_LSS_MAX_SPECS` restores a budget
  without a rebuild, and `muTie`'s removal (B5) makes that backstop the only
  remaining bound on the specs→members→keys spiral.

## §3 WHAT THIS COSTS — read before starting

Removing a default-OFF flag deletes dead code. Removing a default-ON flag deletes
**the escape hatch**, and that is a different transaction:

1. **The flags are the bisection instrument.** The solo census
   (`benchmarks/flag-off-lss-solo-findings.md`) was only possible because each
   mechanism could be disabled alone. After this work the only available bisection
   is `lss.enabled` — all or nothing across 29 mechanisms.
2. **Several of these flags have a recorded miscompile history**, and their
   env var is what made the miscompile diagnosable in the field:
   `arrowSolverRoots` (false-singleton `Task.map f` → identity map),
   `papMembers` (the same class, via its `sigRootIdentity` pairing),
   `postSettleDevirt` (the E9.5 `matchSpec` minimum-SpecId miscompile).
   After removal, a new instance of that class is a code change, not a flag flip.
3. **Knowledge attached to the flag dies with it** unless it is moved. Each flag's
   doc comment carries its ship date, measured effect and traps — that is the
   only record of why the behaviour is what it is.

### Mitigations, all cheap

- **Tag the pre-removal commit** and name the tag in this plan, so a future
  bisect can check out a tree where every mechanism is still switchable.
- **Move each flag's doc comment into the code it gates** rather than deleting
  it with the field. The measurement is the valuable part, not the `Bool`.
- **Record the census row per flag in §7 of this plan** — what it did, what it
  cost — so the evidence survives independently of the source.
- **Batch and gate** (§4): byte-identical emission after every batch, so a
  behaviour change is attributed to ≤ 6 flags rather than to 31.

## §4 ORDER — six batches, by coupling and risk

Each batch ends with the §5 gate. Batches are ordered so that the riskiest
removals happen when the harness is already proven on this tree.

| # | Batch | Flags | Why grouped |
|---|---|---|---|
| B1 | the default-OFF pair | `flow.connect`, `keyedGlobals` | pure deletion, already measured inert; proves the gate |
| B2 | stamping specialists | `stamp.papFast`, `stamp.flatPeel`, `postSettleDevirt`, `devirtFnGlobals` | each owns one decline counter, no coverage coupling |
| B3 | the flow group | `flow.letOverlay`, `flow.accessFlow`, `flow.litFacts` | all hook `Translate`'s walk — **first merge opportunity** |
| B4 | the settle chain | `settle.varSucc`, `settle.varCtorRows`, `settle.varLambda`, `destrAnno` | **the §1 payoff**: five traversals collapse |
| B5 | injection / spine | `injTotal`, `refPapSpine`, `rootFold`, `stamp.rootFoldDepth`, `groundStandalones`, `rsTop`, `muTie`, `instanceQual`, `stamp.useInject`, `stamp.useInjectPap`, `layoutQualMembers`, `sigFlow` | the bulk; `sigFlow` (15 sites) and `layoutQualMembers` (11) are the largest surfaces |
| B6 | identity + keying | `arrowIdentity`, `regIdentity`, `refIdentity`, `arrowSolverRoots`, `papMembers`, `keyed` | highest risk: the miscompile-history set and the largest behavioural surface; do last, alone |

**B6 is deliberately last and deliberately its own batch.** Those six are the
mechanisms whose removal is hardest to reverse and whose failure modes are
soundness, not performance.

## §5 GATE — byte-identical emission, every batch

Fixing a flag at its default must change nothing. The gate is the one that caught
nothing and proved everything in the previous removal:

1. **Fixed-workload byte equality.** A pre-batch binary and a post-batch binary
   compile the same external workloads (`test/elm/src` sample +
   `examples/src/Hello.elm`) to byte-identical MLIR. This is the decisive gate: a
   self-compile equality is NOT available, because the workload is the edited
   source.
2. `cmake --build build --target elm-tests` — at the standing set (13,556 / 12).
3. `cmake --build build --target full` — 1,727 / 1,727.
4. **Bootstrap** (`--target bootstrap`) after B4 and after B6 at minimum; both
   fixed points, Stage 4b and Stage 8c.
5. **A census row** (`flag-off-lss-solo.sh base` equivalent) after each batch:
   coverage, stamping and dispatch identical to the pre-batch baseline. This is
   cheap (~9 min) and catches an analysis change that emits the same bytes on the
   sample workloads but would diverge elsewhere.

**Do not skip (1) in favour of (2)+(3).** The test suites check behaviour; only
byte equality checks that behaviour did not change *at all*.

## §6 THE PAYOFF — what becomes possible, concretely

This plan does not itself merge anything. It removes the reason the merges are
impossible. Named candidates, in the order the batches unlock them:

- **The settle chain (B4).** Five registry traversals
  (`settleVarCtorRows`, `settleCtorRows`, `settleVarSuccessors` ×2,
  `settleVarLambda`) become schedulable as one walk with an internal ordering.
  The double `settleVarSuccessors` exists only because the passes must stay
  separable.
- **The flow group (B3).** `letOverlay`, `accessFlow` and `litFacts` each add
  conditional work to `Translate`'s expression walk; fixed, they are three
  arms of one walk rather than three guarded overlays.
- **`sigFlow` (B5).** 15 consumer sites is the largest single-flag surface in
  the solver; unconditional, its signature-channel work can be folded into the
  inference walk instead of being gated at each site.
- **Dead-branch elimination at 134 sites.** Every removed conditional is a
  branch the Elm compiler currently cannot fold.

## §7 THE EVIDENCE THAT MUST SURVIVE THE FLAGS

From `benchmarks/flag-off-lss-solo-findings.md`, the 2026-09-18 solo census —
per-flag effect and cost, measured one flag at a time on the shipping compiler.
**Copy the relevant row into the code comment when its flag is removed.**

| Flag | artifact | headline effect when OFF |
|---|---|---|
| `arrowIdentity` | −313 KB | `var` 572 → 20,375 |
| `rootFold` | +312 KB | `kN` 2,586 → 63,050 |
| `refIdentity` | −226 KB | `noInstance` −7,921 |
| `regIdentity` | +214 KB | `var` → 19,131, ⊤ → 11,333 |
| `stamp.rootFoldDepth` | +157 KB | `k1` → 113,110, `kN` → 34,745 |
| `layoutQualMembers` | +650 KB | `kN` +24,390, `noInstance` +5,935 |
| `sigFlow` | +131 KB | `noInstance` +36,902, `k1` −56,767 |
| `stamp.flatPeel` | −43 KB | `bodyMismatch` 1,415 → 67 |
| `stamp.papFast` | −31 KB | `noInstance` +3,331, nothing else moves |
| `postSettleDevirt` | −32 KB | `noInstance` +3,719, no coverage change |
| `papMembers` | −61 KB | `var` +3,803 |
| `keyed` | −1.13 MB | `k1` −44,575, `kN` +20,161 |
| others | see findings | `muTie`/`keyedGlobals` inert; `rsTop` k1 −2,047 into ⊤ |

## §8 RISKS

- **A "no-op" removal that is not one.** A default-ON flag whose OFF branch has
  side effects beyond the obvious (census counters, state threading) can change
  behaviour when the branch is deleted rather than the condition. Delete the
  BRANCH, keep the effectful statements, and let the byte gate decide.
- **`lss.enabled` must keep working.** It is the surviving flag, and every
  removed flag's guard is currently `enabled && X`. Collapsing those to
  unconditional must preserve the `enabled` conjunct, or `ECO_MONO_LSS=0` silently
  stops disabling things. **This is the single most likely defect in the whole
  plan** — 29 opportunities to drop the wrong half of an `&&`.
- **Config record shape.** `LssConfig` is back to 27 fields after the last
  removal; this takes it to ~6. The positional `lssDecoder` must lose its
  `D.apply` lines in step with the fields, and eco-config.json files naming a
  removed key must be rejected or ignored deliberately, not by accident.
- **Hash tokens.** Every removed flag's token disappears from `Config.hash`. All
  are emitted only when non-default, so the DEFAULT hash is unchanged and caches
  stay valid — but a build pinned to a non-default value will silently change
  meaning. Grep `eco-config.json` in the tree before starting.

---

# IMPLEMENTATION LOG — 2026-09-18

## §9 THE GATE AS BUILT

The plan's §5.1 gate is realised as a **633-workload fixed-workload rail**:
every `test/elm/src/*.elm` (632 modules) plus `examples/src/Hello.elm`, each
compiled to MLIR by the Stage-1 `guida.js` built from the edited tree
(`compiler/bin/index.js`), with `ECO_MONO_LSS_REPORT=1` on. Two artefacts per
run:

- **`<tag>.manifest`** — per-workload MLIR sha256. This is §5.1's byte gate.
- **`<tag>.census`** — the `=== LSS census ===` block of every workload,
  65,508 lines. This is §5.5's analysis gate, per workload rather than per
  self-compile, and it is **strictly sharper than the emission gate**: it
  moves when coverage/`var`/⊤/stamping move even where the bytes do not.

Both were validated before use:

- **Deterministic.** Two consecutive runs of the same tree: manifests
  identical, census diff 0 lines (after scrubbing the output path, the only
  run-varying text).
- **Sensitive.** `ECO_MONO_LSS_ROOT_FOLD=0` moves 16 of the 633 manifests.
- **Cache-honest.** The harness wipes `eco-stuff`/`elm-stuff` per run; a
  cold-cache run of the B1 tree reproduced the warm-cache manifests and
  census exactly, so the front-end artifact cache was never masking a change.

Runtime ≈70 s per gate (8-way parallel, one project dir per worker).

**On §5.5's "dispatch".** The census artefact carries coverage
(`coverage: positions=… k1=… kN=… var=… top=…`) and the stamping counters
(`lss globalopt: … dispatchUpgraded=… declined*=… devirtPost=…`) per workload,
which is what "coverage and stamping" asks for. RUNTIME dispatch is not
measured separately and does not need to be: it is a function of the emitted
code, and emission is byte-identical across all 633 workloads at every batch —
and, after B4 and B6, across the bootstrap's two fixed points as well. Dispatch
equality follows from byte equality rather than being an independent check.

The rail is installed as **`benchmarks/mlir-workload-rail.sh`** so it outlives
this work: `mlir-workload-rail.sh <tag>` records the two artefacts,
`DIFF=<other-tag> mlir-workload-rail.sh <tag>` prints the comparison. It builds
nothing on purpose — the tag names a tree you chose and built yourself.

**Deviation from §3's first mitigation.** "Tag the pre-removal commit" could
not be done: this worktree's `gitdir` does not resolve in the build container,
so no git command runs here. Substituted: a verbatim copy of the pre-removal
`compiler/src` is kept for the session, and every removed flag's measured
evidence is moved into the code it gated (§3's second mitigation) and recorded
per batch below (§3's third).

## §10 BATCH RESULTS

| # | Batch | Emission (633) | Census | elm-tests | E2E | Bootstrap |
|---|---|---|---|---|---|---|
| B1 | `flow.connect`, `keyedGlobals` | byte-identical | identical | 13,556 / 12 | 1,727 / 1,727 | — |
| B2 | `stamp.papFast`, `stamp.flatPeel`, `postSettleDevirt`, `devirtFnGlobals` | byte-identical | identical | 13,555 / 12 | 1,727 / 1,727 | — |
| B3 | `flow.letOverlay`, `flow.accessFlow`, `flow.litFacts` | byte-identical | identical | 13,549 / 12 | 1,727 / 1,727 | — |
| B4 | `settle.varSucc`, `settle.varCtorRows`, `settle.varLambda`, `destrAnno` | byte-identical | identical | 13,543 / 12 | 1,727 / 1,727 | both fixed points |
| B5 | `injTotal`, `refPapSpine`, `rootFold`, `stamp.rootFoldDepth`, `groundStandalones`, `rsTop`, `muTie`, `instanceQual`, `stamp.useInject`, `stamp.useInjectPap`, `layoutQualMembers`, `sigFlow` | byte-identical | identical | 13,526 / 12 | 1,727 / 1,727 | — |
| B6 | `arrowIdentity`, `regIdentity`, `refIdentity`, `arrowSolverRoots`, `papMembers`, `keyed` | byte-identical | identical | 13,523 / 12 | 1,727 / 1,727 | §16, both fixed points |

**B1 is not merely neutral — it is the plan's one measured performance win.**
`flow.connect` was the most expensive inert flag in the 2026-09-18 solo census:
byte-identical artifact with it off, while costing 32.6 M generic dispatches
(−3.51 %), 51 minor GCs and ~4.6 % wall. Removing the mechanism with the flag
banks that. Every other batch is, by construction, exactly neutral: the flag
was fixed at the default the shipping compiler already used.

The **failure set** is identical in every batch and equals the standing 12:
eleven POST_010 / TYPE_007 node-type checkers plus the golden constraint
fingerprint `if-chain`, which `GoldenConstraintTest.elm` itself records as
"ALREADY failing before any of this work". The **pass** count falls batch by
batch by exactly the number of flag-arm test legs deleted with their flags —
never by a test that started failing.

## §11 WHAT THE REMOVALS COST THE TEST SUITE

§3.1 said the flags are the bisection instrument. In the unit suite that is
literal: many LSS pins are **differentials** that toggle one flag, and the
suite's own rule (`LssSigFlowTest`'s module doc) is *a differential test must
pin every flag that overlaps the one it toggles*. Once nothing is pinnable,
those pins cannot exist. Per file, what was kept, what went, and where the
deleted arm's finding now lives:

- **`LssFlowEdgeLossTest`** — the whole bare-inference arm (settle off) is
  gone; tests 1 and 2 with it. Their measurements — producer C's call-result
  argument arrives all-set, producer V's bare-reference argument arrives
  (set head, VAR interior) with the producer's own row carrying the same var
  — are now recorded in the module doc as the §9.1 finding they were. Test 3
  (shipped defaults) survives and is the file's remaining executable pin.
- **`LssVarSuccTest` / `LssVarCtorRowsTest`** — the "additive-only" pins
  compared the two arms on a fully-covered fixture. They become the coverage
  claim they rested on: no var survives at the measured positions.
- **`MuTieTest`** — the μ-tie can no longer be isolated (`layoutQualMembers`
  and `arrowSolverRoots` each close the spiral on their own, and both are
  gone). The termination property survives at shipping defaults, no longer
  attributed to one mechanism; the deleted arm's measurement (fan-out to the
  pinned budget of 64, nothing tied) is in the harness comment.
- **`LssSigFlowTest`** — 1b/2/3/5 deleted (the four pure differentials), with
  their flag-off readings recorded in the harness comment. 1a/4/6/7/8/9 are
  absolute pins and stay.
- **`E5KeyedDispatchTest`** — retargeted at B1 from selective keying
  (`lss.keyedGlobals`, deleted) to all-globals keying, which is the same
  mechanism applied to every global; the pin's content was unchanged by that
  move. B6 then cost it its assertion — §14, the one pin in the whole plan
  that had to be WEAKENED rather than merely lose an arm.
- **`AbiCloningFlatPeelPassTest`, `AbiCloningPapFastPassTest`,
  `PostSettleDevirtTest`, `AbiCloningFenceTest`, `LssDestrAnnoTest`,
  `LssVarLambdaTest`, `LssRefPapSpineTest`, `LssInjTotalTest`,
  `LssLetOverlayTest`, `LssAccessAndLitFactsTest`,
  `LssLocalMultiUseInjectTest`, `LssRootFoldTest`, `LssGroundingTest`,
  `LayoutQualTest`** — each keeps its ON-arm assertions and loses its
  flag-off leg, with that leg's finding written into the module doc or the
  harness comment.

**This is the real, permanent cost of the plan, and it is larger than §3
anticipated** — §3 priced the loss of the *field* escape hatch, not the loss
of the *unit-level* differential. A future regression in one of these
mechanisms will surface as a changed artifact on the 633-workload rail or as
an E2E failure, not as a flipped unit pin naming the mechanism.

## §12 THE §8 TOP RISK, AUDITED

§8 named "29 opportunities to drop the wrong half of an `&&`" as the single
most likely defect. It is audited mechanically after every batch by diffing
the `lss.enabled` guard TEXT against the pre-removal tree:

    diff <(grep -h 'lss\.enabled' <pristine>/<file> | sort) \
         <(grep -h 'lss\.enabled' compiler/src/<file>  | sort)

Every surviving guard must still contain `lss.enabled`, and every guard that
disappeared entirely must be one whose whole mechanism was deleted (the two
default-OFF `flow.connect` sites, B1). Through B4 that holds at every site in
`Translate`, `Monomorphize`, `LssInfer`, `Engine` and `AbiCloning` — the
`enabled` conjunct is preserved in all 56 surviving sites, down from 58 by
exactly the two deleted `flow.connect` guards.

## §13 §8's OTHER RISKS, RESOLVED

- **Config record shape.** `lssDecoder`'s `D.apply` chain is POSITIONAL, and
  its own comment says an insertion anywhere above silently swaps two flags'
  values while still type-checking. Every field removal drops its `D.apply`
  line in the same edit, and the final chain was read back against the final
  record field-for-field.
- **Hash tokens.** `grep` for `eco-config.json` over the tree (build outputs
  excluded) finds **none**, and no JSON in the repo carries an `lss` block. No
  build is pinned to a non-default LSS value, so the "silently changes
  meaning" case §8 warns about has no instance here. Of the removed tokens
  only `lssK=1` and `lssDF=1` were emitted at the DEFAULT (the rest ride the
  non-default arm), so the default `Config.hash` string does change and
  caches re-key once — which is a rebuild, not a behaviour change: the hash
  keys the Details cache and never reaches emitted MLIR.
- **`ECO_MONO_LSS=unkeyed` changes meaning.** It used to select
  `keyed = False`; all-globals keying is unconditional under LSS now, so the
  value is accepted as a no-op and documented as one. This is the one
  deliberate behavioural change to a non-default environment value in the
  whole plan.
- **Deleted `ECO_MONO_LSS_*` variables are silent no-ops.** Nothing rejects an
  unknown `ECO_*` name, so a stale flag-off benchmark row would read as a
  genuinely inert flag — the exact misreading `flag-off-lss-loop.md` exists to
  prevent. Both flag-off scripts and the protocol doc therefore carry an
  expiry banner naming the removal and pointing at the last census taken while
  the flags existed.

### Bootstrap after B4 (§5.4)

`cmake --build build --target bootstrap`, exit 0 in 57m43s. **Both fixed points
hold**: Stage 4b (JS, `eco-boot-2.js == eco-boot-3.js`) and Stage 8c (native,
`eco-compiler-boot == eco-compiler-boot-2`). Stage 5's MLIR and Stage 7a's are
the same size to the byte — 13,380,094 B — i.e. the JS-built compiler and the
native compiler emit the same artifact. Stage 9b's unified-eco self-compile
completed too.

## §14 THE ONE PIN THAT HAD TO BE WEAKENED — `E5KeyedDispatchTest`

Every other test repair in §11 deletes an arm and keeps its assertion. This one
could not: after B6 the assertion itself stopped being true of the fixture.

The pin was a RED/GREEN pair on `lss.keyed` — the keyed arm asserted **two
DISTINCT** stamped fast evaluators (per-site fan-out, not one lucky stamp), the
unkeyed arm asserted **none**. Removing `keyed` takes the unkeyed arm, which was
expected. What was not expected is that the KEYED arm then measured **one**
stamp, not two.

The cause is a second flag: this harness had `lss.arrowIdentity` pinned **OFF**.
Arrow identity makes repeated loads of one stamped type object share a set slot
— it is the removal of LSS_006's per-load fragmentation — so with it on, the
fixture's two call sites share an arrow slot and keying fans out ONE stamped
evaluator. The fixture had only ever shown two under a configuration the
shipping compiler does not use.

So the pin is now "keying makes the site stamp at all" (`n >= 1`), with the
module doc carrying what the deleted arms measured and why the count fell. This
is a genuine loss of assertion strength and it is recorded as one.

**It is not a regression.** The whole point of the 633-workload rail is to tell
these two cases apart, and it does: emission is byte-identical against the
pre-removal baseline at B6, as at every other batch. A unit expectation that
moves while every emitted byte holds is a fixture measuring a non-shipping
configuration — which is the same finding as §11, in its sharpest form.

## §15 FINAL STATE

| | before | after |
|---|---:|---:|
| `LssConfig` fields | 27 | **7** |
| `ECO_MONO_LSS*` env vars | 33 | **8** |
| sub-records | 3 (`flow`, `settle`, `stamp`) | 1 (`stamp`) |

```elm
type alias LssConfig =
    { enabled : Bool            -- the one switch
    , maxSetSize : Int          -- cap  (0 = unlimited)
    , maxSpecsPerGlobal : Int   -- cap  (0 = unlimited)
    , report : Bool             -- census
    , qCensus : Bool            -- census (verifier)
    , arrowCensus : Bool        -- census
    , stamp : LssStampConfig    -- { maxInstances : Int, census : Bool }
    }
```

The surviving env vars are `ECO_MONO_LSS`, `_REPORT`, `_MAX_SPECS`,
`_MAX_SET_SIZE`, `_INSTANCE_QUAL_MAX`, `_QCENSUS`, `_CENSUS`, `_ARROW_CENSUS` —
one switch, three caps, four censuses, and nothing that selects between two
code paths.

`lss.enabled` survives at **51 guard sites**, every one of them carrying the
conjunct it carried before (§12).

### What §6 unlocked, as it now stands

The settle chain is the plan's own example, and it is now exactly the shape §6
described — five invocations whose only remaining guard is `lss.enabled`:

```elm
settleVarSuccessors
    (settleVarLambda
        (settleVarSuccessors (settleCtorRows (settleVarCtorRows sDrained)))
    )
```

Nothing forces those to stay five traversals any more, and the ordering
constraint that made `settleVarSuccessors` run twice is now expressible as a
statement inside one walk. Likewise `Engine.lambdaInstanceMemberGo` is a
one-line forwarder, `AbiCloning` no longer threads a constant `fpFence` through
~30 functions, and the flow group is three unconditional arms of one
`Translate` walk. **This plan deliberately stops here** (§6: "This plan does
not itself merge anything"); the merges are follow-on work, and
`benchmarks/lss-payoff.md` is the track that will price them.

### The re-gate after the doc-coherence pass

Fixing the flags left a scatter of comments describing a shape that no longer
exists — `LssConfig`'s field list, two "`LssConfig` is AT the 32-slot cap"
notes (it is 7 fields now; the CAP has not moved, and it is still why `stamp`
is a sub-record), five `flag-on`/`flag-off` phrasings in `AbiCloning`, and
three places that told a reader a gate lived somewhere it no longer does — the
LSS_023 kernel-tunnel selector in `LssInfer` and its `Translate` twin, and
`Store.addSlotSource`'s "or `LsFrom` escapes into flag-off stores" obligation.
Those three are the ones worth the edit: a comment naming a removed flag as
HISTORY is the established idiom here (`lss.spineArity` and `lss.callArgFlow`
have read that way since 2026-09-17), but a comment that says *the gate lives
HERE* sends a reader looking for code that is not there.

Comment-only, and re-gated on the 633-workload rail rather than assumed inert:
**byte-identical, census diff 0**, elm-tests 13,523 / 12 at the standing set.

The post-B6 bootstrap was started, then stopped three minutes in when these
were found, and re-run from scratch on the final tree — a caveated fixed point
("the bootstrap covers this tree modulo some comment edits") is not worth
saving an hour for.

### Size of the change

`compiler/src` is **−2,529 lines across 14 files**. The two `Eco/Config.elm`
files are 79 % of that (−1,080 and −907): the flag docs, the decoder lines, the
hash tokens and the env plumbing. The rest is the gated code itself, led by
`Translate.elm` at −319 (the `flow.connect` mechanism plus the guard collapses)
and `Engine.elm` at −96.

§1's count of **134 flag consumer sites** is now **102 config reads in total**,
and all 102 are of a KEPT field — `enabled` (51), `report` (36), `maxSetSize`
(6), `qCensus` (4), `arrowCensus` (2), `maxSpecsPerGlobal` (2), `stamp` (1).
Not one of them selects between two mechanisms.

### Files touched

- **`compiler/src`** — 14 files, −2,529 lines (above).
- **`compiler/tests`** — 27 files, every one an LSS pin (§11/§14). The
  `keyed = True` sweep rewrote only files it actually changed; nothing else in
  the suite was touched.
- **`design_docs/invariants.csv`** — one new row, `LSS_041`, recording the
  removal. The 24 existing rows that name a removed flag stay as they are:
  their statements are still TRUE, only the flag names are historical, which
  is already the file's idiom (`lss.spineArity`, `lss.callArgFlow`).
- **`benchmarks/`** — `mlir-workload-rail.sh` added (the gate);
  `flag-off-lss-solo.sh`, `flag-off-lss-run.sh` and `flag-off-lss-loop.md`
  given expiry banners.

**Audited textually, then verified empirically.** The `&&` audit is a source
check; it says the conjunct is still written, not that the switch still works.
So the switch was also exercised directly on the final tree — three workloads
compiled with `ECO_MONO_LSS=1` and `=0`:

| workload | LSS on | LSS off |
|---|---:|---:|
| `DictMapStagedCaptureTest` | 6,002 B | 6,181 B |
| `CombinatorRefIdentityBugTest` | 2,104 B | 2,219 B |
| `HigherOrderTest` | 1,347 B | 1,451 B |

Different, and larger with it off, in every case — `ECO_MONO_LSS=0` still
disables lambda-set specialization rather than having been quietly collapsed
into the always-on path. That is the failure §8 named, and it did not happen.

## §16 BOOTSTRAP AFTER B6 (§5.4) — THE CLOSING GATE

`cmake --build build --target bootstrap`, exit 0 in 55m44s on the final tree.
**Both fixed points hold**: Stage 4b (JS, `eco-boot-2.js == eco-boot-3.js`) and
Stage 8c (native, `eco-compiler-boot == eco-compiler-boot-2`). Stage 9b's
unified-eco self-compile completed.

One number is worth reading twice. The compiler's own MLIR:

| | Stage 5 / 7a output |
|---|---:|
| after B4 | 13,380,094 B |
| after B6 | 13,304,208 B |
| | **−75,886 B (−0.57 %)** |

That is NOT a change in what the compiler emits — the 633-workload rail is
byte-identical against the pre-removal baseline at every batch, including this
one. It is the compiler's own artifact getting smaller because its own SOURCE
lost 2,529 lines of branch that the Elm compiler could not fold while the flags
were live. §6's last bullet — "dead-branch elimination at 134 sites; every
removed conditional is a branch the Elm compiler currently cannot fold" — priced
in the abstract, and this is it measured: the compiler compiling itself is the
one workload where the removal is visible in the output.

## §17 THE OTHER HALF OF `enabled` — THE LSS-OFF RAIL

The 633-workload rail gates the **default** path. That leaves the other half of
§8's top risk untested: a guard that lost its `enabled` conjunct would emit the
same bytes at defaults (both arms are "on" there) and only diverge with LSS
**off**. The `&&` audit (§12) is a source check and cannot see that either — it
proves the conjunct is still written, not that it still does anything.

So the rail was run a second time, both arms under `ECO_MONO_LSS=0`:

- **arm 1** — the PRE-removal compiler, built from the pristine source snapshot
  in its own shadow root (`src` symlinked at the snapshot, reached through
  `GUIDA_JS_PATH`) so `/work/compiler/src` is never touched;
- **arm 2** — the final tree.

**Result: BYTE-IDENTICAL, 633/633.**

Both paths through `lss.enabled` therefore emit exactly what they emitted
before the removal — the ON path at every batch, and the OFF path here. Taken
with the empirical switch check in §12 (`ECO_MONO_LSS=0` still produces
different, larger MLIR than `=1`), `enabled` provably still means what it
meant, which is the one property the whole plan rests on.

The check is `scratchpad/offpath.sh` in shape; it is not installed in
`benchmarks/` because it is a ONE-OFF — it compares against a pre-removal
snapshot that only existed for this work. The reusable half is
`mlir-workload-rail.sh`, which it drives twice.

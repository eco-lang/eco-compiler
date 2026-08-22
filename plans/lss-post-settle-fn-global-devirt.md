# Post-settle fn-global devirt (E9.5 — the commit-after-settle completion of E9.1) — census first

**Status: LANDED DEFAULT-OFF (2026-08-22; §4.R has the execution record —
reach acceptance EXACT: devirtPost 86/311/0 = the census table to the
digit; neutrality EXACT: minor/major GC identical across arms). The build
supersedes the 2026-08-21 PARK on a criterion change, recorded below. Phase 0 RAN (§2.R) and its heat verdict stands unchallenged for the
self-compile: the admissible slice upper-bounds at ≈0.24% of dispatch
there. The PARK is superseded on a CRITERION change, not a numbers change:
the commissioning decision (2026-08-22) is that this plan's aim is
**LSS reach completeness** — every singleton the analysis mints should be
exploitable — and self-compile heat is the wrong admissibility gate for
that aim (`Tuple.pair`/`Basics.always`-shaped code is exactly what other
workloads do more of than a compiler does). Precedent: LSS_018 μ-tie
flipped default-on with a ZERO eligible self-compile population because
the mechanism closes a hole other workloads can hit. Scope is WIDENED per
§2.R.5: the rewrite covers `g` AND `c` origins in one arm (the ctor class
is 3× the fn-global class and mechanically identical, with a strictly
simpler soundness story). Acceptance is re-based on reach + NEUTRALITY
(§4.3): counters move exactly as the census predicts, wall FLAT, full
battery — no event-recovery bar. `k` stays E10's; `l` stays the LSS_024
index-completeness track's.** Successor to the
E9.1/E9.3 arc of `plans/lss-dispatch-value-extraction.md` and the fn-global
half of the E10 commit-after-settle architecture sketched there (§11.6). All
code references verified at HEAD 2026-08-21 (post-LSS_024, post the
`lss.sigFlow` + `lss.layoutQualMembers` default flips).

**Scope correction this plan starts from (recorded in
`plans/lss-per-use-let-separation.md` §2.R.6 and the fidelity mapping's
GAP-9 entry, both amended 2026-08-21).** The Phase-H census's re-rank line
briefly mis-stated the E9.1 lever two ways, and this plan exists to chase
the corrected version:

1. `lss.devirtFnGlobals` (E9.1) has been **DEFAULT-ON since Run L,
   2026-07-20** (`benchmarks/runtime-calls.md:628` — Tier 1 defaults;
   `Config.elm:332`). "Exploit E9.1" cannot mean flipping a flag.
2. The "64.9% of ⊤ sites are global-callee" figure is a POPULATION share
   over EVERY `MonoCall` (`stampCall` consults every call — kernel-callee
   sites are direct by construction), not dispatch weight. It must not be
   used to size anything.

What remains, and is real on the current tree: **`declinedNoInstance =
1,394`** (un-gated AbiCloning counters, 2026-08-21 census, default-semantics
arm) — call sites whose callee head annotation is a SINGLETON `{m}` where
`m` has no `MonoClosure` instance in AbiCloning's index. Standalone `g|`
(function-global) members have no closure instances BY DEFINITION, so every
singleton-`g|` site that translate-time E9.1 did not devirtualize lands
here: precision the analysis already minted, exploited by nothing.

## §0 Evidence and the populations, precisely

### 0.1 What E9.1's translate-time arm captures — and its four misses

`Translate.devirtGlobalTarget` (Translate.elm:2140-2166) rewrites an
indirect call to a DIRECT call (`translateVarRef` — spec enqueued at the
site's own type; `MonoCall` with `defaultCallInfo`; staging/codegen emit the
direct form) when ALL of:

- callee is a plain var (`calleeIsPlainVar` — VarLocal/TrackedVarLocal;
  a var read is effect-and-bottom-free, so dropping it is sound — LSS_015's
  clause);
- head annotation is singleton `{g|G}` where G's node is body-bearing
  (`isBodyNode`: Define/TrackedDefine/Cycle, Link-chased) — ctors take the
  E9 arm; kernel ALIASES route to the E9.2 whitelist (the CGEN_038 lesson);
- **G has a type annotation** (`lookupAnnotation` — `Ok Nothing` declines,
  uncounted);
- **`arity >= 1 && arity == argCount`** where arity = the ANNOTATION's
  arrow-spine length — exact saturation only (v1 kept EXACT; under- and
  over-application decline, uncounted).

The misses, each a candidate class for this plan's census to size:

- **M1 (late-settle):** the annotation is not yet a singleton when the
  site's spec translates; later joins sharpen it, but only JOIN-dirtied
  specs re-translate (LSS_010), so the site keeps its indirect call while
  the final graph carries the singleton. This is the exact class E10 §11.6
  names for kernels ("commit-before-settle"), on the g| axis.
- **M2 (under-application):** argCount < arity — the site builds a PAP of
  a statically-known global through the generic path.
- **M3 (over-application):** argCount > arity of the first stage.
- **M4 (unannotated target):** annotation-less globals never devirt (arity
  is read from the annotation only).

### 0.2 Prior dynamic evidence (why the census may well PARK this)

The 2026-08-21 decline-log arc (`benchmarks/runtime-calls.md:1673-1718`)
weighed the SIGFLOW-DELTA slice of this population (+133 noInstance sites,
interned-range `g|`-class) and concluded **"fn-global slice ≈ no event
weight"** — the hot de-stamps were the LSS_024 key-split class instead. That
verdict is about the DELTA between arms, not the absolute 1,394-site
population on today's tree, which has never been weighed. The expectation
cap it sets is real: the E9.1 flag itself was worth −53.1M dispatch
events/run (Run I) and that pool is already banked; this plan fights for a
residual. The tier-roadmap lesson binds: static censuses collapse at
admissibility gates — **no GO without dynamic heat.**

### 0.3 What already exists for a post-settle arm (no new plumbing)

- `Mono.MonoGraph.lssMemberOrigins : Dict Int MemberOrigin` — mid →
  `OriginGlobal Global | OriginKernel | OriginCtor | OriginAccessor` —
  built at solver assemble, survives Prune/MonoInlineSimplify
  (Monomorphized.elm:1722-1737). Member→target resolution post-mono is a
  Dict lookup.
- `registry.reverseMapping : Array (Maybe (Global, MonoType))` — SpecId →
  (family global, spec key type). Inverting once gives Global →
  [(SpecId, MonoType)]; `Mono.eqLayout` (annotation-blind) matches the
  site's callee type against candidate spec types.
- `MonoVarGlobal Region SpecId MonoType` is the direct-reference form, and
  `annotateCallStaging` runs AFTER AbiCloning
  (MonoGlobalOptimize.elm:150-155), so a call rewritten at AbiCloning time
  gets staging attributes through the same pass every written-out direct
  call uses.
- The rewrite position is `stampCall`'s `Dict.get m index == Nothing` arm
  (AbiCloning.elm:1256 — today `bumpNoInstance`).

### 0.4 What a post-settle devirt does NOT get (payoff honesty)

`MonoInlineSimplify` runs BEFORE GlobalOpt (Builder/Generate.elm:786→961),
so calls devirtualized here are **never inlined** — unlike translate-time
E9.1, whose main payoff was the inlining it unlocked (Run I: output +1.67%
of inlined bodies). The win per event is generic-dispatch-funnel → direct
call, nothing more. The census's dynamic bar must be set accordingly.

## §1 The thesis

Commit-after-settle, applied to the `g|` class: at AbiCloning time every
annotation is final, so the devirt decision that translate had to make
early (and therefore conservatively) can be made exactly. A singleton
`{g|G}` at a plain-var callee states that the ONLY runtime inhabitant of
that arrow is G's own value — a **zero-capture** closure/PAP-0 of some spec
of G (exact-arity saturation excludes partially-applied values: with
`spineArity = False`, `g|` members live on the HEAD arrow only, and a
k-applied PAP's remaining spine does not carry them; the arity guard is the
belt to that suspender). Rewriting the call to a direct call of ANY
eqLayout-matching spec of G is then sound:

- **No E11 hazard.** The representative-hijack class (LSS_024 §1.1)
  requires a CAPTURE RECORD read by a body it was not built for — divergent
  same-layout clones crash through their captured continuations. A bare
  global's value has zero captures; the rewritten call passes only the
  site's args, and the chosen spec's body is internally self-consistent.
  Spec choice among same-layout candidates changes dispatch tiers inside
  G's body, never observable behavior — LSS_005 covers exactly this.
- **Same soundness clause as LSS_015/E9.1** for dropping the var read
  (effect-and-bottom-free).
- **Kernel-alias hazard (CGEN_038) does not arise here**: the translate-time
  danger was the INLINER planting a raw kernel call at an imprecise site;
  no inline pass runs after GlobalOpt, so a direct call to an alias spec
  stays a call to that (correctly-typed) spec. Pinned by a fixture anyway
  (§4.2) — the alias class is where this repo has already crashed once.

## §2 Phase 0 — the census (the gate for everything below)

One-shot instrumentation, decline-log discipline; the Phase-H census
(`plans/lss-per-use-let-separation.md` §2.R.1) is the worked example,
including the fold-per-member point-key discipline (not needed here — this
is post-mono, one store) and the honesty-caveat format.

### 2.1 Static classification (one-shot, JS fast loop, default config arm)

Extend `stampCall`'s noInstance arm (report-gated, removed after the run)
to log per site:

    NOINST | <spec> | m<id> | <origin g/k/c/a/l> | <calleeShape> |
    args=<n> | arity=<spine of callee MonoType> | specs=<eqLayout matches>

where `specs` is computed against a one-shot Global→[(SpecId, MonoType)]
inversion of the registry (OriginGlobal rows only). Aggregate counters ride
`AbiCloningStats` (one nested one-shot record).

**Deliverable 1 — the admissible table.** Sites with origin `g`, callee
shape `local`, `args == arity`, `specs >= 1` — the population §3's rewrite
would fire on, per site with target names. Rows (recorded, not targets):
the M2/M3 arity slices, `specs == 0` (layout-miss), origin `k` residue
(E10's kernel class), origin `l` residue (index misses of lambda members —
LSS_024's leftover), unannotated-vs-late-settle split is NOT statically
distinguishable and is not attempted.

### 2.2 Dynamic heat (the admissibility gate)

One census-on leg of the preserved counters-lowered binary
`build/compiler/build-kernel/bin/eco-compiler-sflq` (Run AC's
sf+lq-forced build = today's default semantics; the binary predates the
default-flip COMMITS but the env forced the same configuration — recorded
caveat: its source differs from HEAD only in the flipped defaults and doc
text) on the cold SUBST workload, `ECO_DISPATCH_STATS=1`, symbolized with
the FIXED `dispatch-census.sh` (hex2dec + binary search — the aliasing trap
is closed). **Upper bound** = Σ `sat` over fps whose symbols belong to the
admissible targets' specs (an over-count: every indirect call through those
globals' values anywhere, not only at admissible sites — biased AGAINST
PARK, which is the safe direction).

### 2.3 Stop conditions (PARK with numbers recorded, no substrate work)

- Admissible population ≈ 0 (the 1,394 dissolves into `l`/`k` residue and
  arity misses).
- Dynamic upper bound immaterial: **< ~2M events** (≈2% of the 88.1M fast
  pool, ≈0.2% of 968M sat — Run AC scale). Even a loose upper bound below
  this cannot pay for a new stamped rewrite class.
- Admissible mass dominated by `specs == 0` layout-misses (post-settle
  cannot enqueue; record for a possible translate-side arity-widening
  follow-up instead).

**GO condition:** a named admissible site set with a material dynamic
bound — mechanism pinned per site (LSS_024-Phase-0 style), plus the §3
build.

## §2.R Phase 0 — RESULTS (2026-08-21). Verdict: **PARK.**

### 2.R.1 Static classification (Deliverable 1)

One cold JS self-compile, default config (`sigFlow`/`layoutQualMembers`
default-on), report-gated NOINST logging in `stampCall`'s noInstance arm.
Raw dump: `/work/lss-e95-noinst-census.txt`. Aggregates
(`declinedNoInstance = 1,387` this build — the census code itself is ~150
lines of corpus, drift −7 vs the uninstrumented 1,394):

| origin class | occurrences | reading |
|---|---|---|
| `l` (lambda member missing from the instance index) | **830** | the LSS_024-leftover index-miss class — not `g|`, not this plan |
| `c` (ctor singletons) | 322 | E9's translate arm missed these; ctor construction is cheap and the class was banked in Run H — row only |
| `k` (kernel singletons) | 135 | E10/E9.2 whitelist territory: `List.cons` 30, `Scheduler.andThen` 21, `Utils.equal` 19, … |
| `g` (fn-global singletons) | **100 (66 rows)** | THE E9.5 population |

The `g` class decomposes exactly as §0.1 predicted, with one surprise:

- **ADMISSIBLE (local callee, exact arity, ≥1 eqLayout spec): 52 sites /
  86 occurrences / 22 targets.**
- `specs = 0` layout-miss: **0** — when the arity matches, the target's
  value-spec ALWAYS exists at the site's layout (the M-late-settle
  "cannot enqueue" worry is empty on this tree).
- Over-applied (M3): 14; under-applied (M2): 0.
- Top targets: `Compiler.Type.Type.mkFlexVar` (30 sites, enclosing specs
  `System.TypeCheck.IO.andThen`/`.map` — the solver family),
  `Basics.always` (22 sites, all in `Combine.bimap`), `Tuple.pair` (4, all
  `Result.map` idioms), then a long tail of n=1 predicates.

### 2.R.2 Dynamic heat (Deliverable 2) — the upper bound and its autopsy

One census-on leg of the preserved Run-AC `eco-compiler-sflq`
counters-lowered binary (cold `eco-stuff`), `ECO_DISPATCH_STATS=1`,
symbolized with the fixed `dispatch-census.sh` (0 unknown fps, all at
symbol starts). **Caveat recorded:** the package typed-artifacts cache was
cold from the day's test runs, so the workload compiled ≈2× Run AC's
(sat 1.939B vs 968M; typed 30.2M ≈ 1×) — every number below is therefore
INFLATED relative to the Run-AC scale, i.e. biased AGAINST the PARK it
still produces. Full table: `/work/lss-e95-dispatch-upper.tsv`.

Upper bound = Σ `sat` over every fp belonging to ANY spec of an admissible
target (counts all indirect calls through those globals' values anywhere,
not just at admissible sites):

| target | sat (this leg) | admissible sites | per-site refinement |
|---|---|---|---|
| `Tuple.pair` | 3,086,416 (39 fps) | 4 | all four are `Result.map Tuple.pair` idioms — the 3.09M lives in the Dict/fold plumbing (`Tuple_pair_$_34270` 1.68M etc.), NOT at these sites |
| `Basics.max` | 1,210,100 (1 fp) | 1 | the one site is a `Basics.composeR` composition |
| `Compiler.Type.Type.mkFlexVar` | **298,119** | 30 | the whole hot-looking `IO.andThen/map` family is bounded here — 0.015% of the leg's sat |
| `Basics.always` | **0** | 22 | the `Combine.bimap` population never executes on this workload |
| everything else (18 targets) | 93,081 | 29 | slivers |
| **TOTAL** | **4,687,716** | 86 | ≈2.3M at Run-AC scale = **0.24% of sat** |

**Verdict per §2.3, stop condition 2** (with condition 1 half-fired too —
the population is 100 of 1,387, dominated by `l`): even the loosest bound
is ≈0.24% of dispatch, and the two targets carrying 92% of it contribute
through non-admissible sites, so the realistic prize is the mkFlexVar
family's ≤298K plus slivers — under 0.05% of dispatch, an order below any
stamped-rewrite payoff this track has ever shipped (E9.1 itself: −53.1M).
**No build. No flag. LSS_025 stays unreserved.** *(Superseded next day on a
criterion change — see the status header and §4.R; the HEAT numbers above
stand unrevised and remain the reason the flag ships DEFAULT-OFF.)*

### 2.R.5 Coverage split by class (added 2026-08-22 — which lever owns what)

Shape analysis of the full NOINST dump (local callee + exact arity = the
devirtable form):

| class | occ | local+exact | over-applied | owner |
|---|---|---|---|---|
| `g` | 100 | 86 | 14 | **THIS plan (§3)** |
| `c` | 322 | **311** | 1 | **THIS plan (§3, widened 2026-08-22)** — identical mechanism via `OriginCtor`; a bare ctor value has zero captures by construction, so the §1 argument applies a fortiori |
| `k` | 135 | 19 | 44 | E10 (§2.R.3) — needs kernel ABI derivation + the E9.2 guards; NOT this mechanism |
| `l` | 830 | 286 | 541 | NOT devirtable by anything — the values are CAPTURING closures; a direct call needs the capture ABI, i.e. exactly the index instance that is missing. LSS_024's index-completeness leftover (and the 541 over-applied are E2.7's) |

This plan therefore covers **397 of the 1,394** noInstance occurrences
(86 g + 311 c ≈ 29%); the rest is owned by other, named levers.

### 2.R.3 Rows recorded for other tracks (not this plan)

- **The `k|` residue is the only warm lead in the noInstance population:**
  cons-valued closures total ≈10.9M sat on this leg (`List_cons_$_15189`
  10.2M + tail; ≈5.4M at Run-AC scale, ≈0.56%), against 30
  `{k|List.cons}` singleton sites (plus `Scheduler.andThen` 21,
  `Utils.equal` 19). That is E9.2-whitelist/E10 commit-after-settle
  territory (`plans/lss-dispatch-value-extraction.md` §11.6), where the
  E9.2 CNumber/shape decline guards are the known cause — any follow-up
  starts there, with this census's site list as its Phase 0 seed.
- The `l` = 830 index-miss class is LSS_024's recorded leftover
  (instance-index misses under keyed clones), already characterized there.
- `declinedShape arity-over = 7,366` (lambda members with instances) —
  E2.7/LSS_014 territory, untouched by anything here.

### 2.R.4 Method notes

Same one-shot discipline as the Phase-H census: report-gated, removed
after the run, tree verified byte-identical afterwards. The registry
inversion + `lssMemberOrigins` classification ran only under the census
flag. The instrumentation seam (threading a census Bool through
`globalOptimizeWithStats` into `abiCloningPass`) is the same one used
twice now — if a third census needs it, consider making `AbiCloningStats`
census mode a permanent report-gated parameter instead of re-threading.

---

## §3 Design (BUILT 2026-08-22 — g AND c origins, per the §2.R.5 split)

- **Flag:** `lss.postSettleDevirt`, env `ECO_MONO_LSS_DEVIRT_POST`, hash
  token `lssDP=1` non-default-only, DEFAULT-OFF at landing. Config default
  `False`; decoder + env override + hash arm mirror `devirtFnGlobals`.
- **Rewrite** (in `stampCall`'s noInstance arm, before `bumpNoInstance`):
  when flag-on ∧ origin `OriginGlobal target` OR `OriginCtor target` ∧
  callee is `MonoVarLocal` ∧ `args == arity(calleeType)` ∧ a
  lowest-SpecId `eqLayout` match exists → replace `func` with
  `MonoVarGlobal region specId calleeType` (site's own type, the
  translate-time precedent — E9's ctor rewrite produces exactly this
  shape), keep args/result/callInfo; count `devirtPost` split g/c.
  Declines: `devirtPostNoSpec` (layout-miss — census expectation ~0);
  everything else falls through to `bumpNoInstance` unchanged. The
  Global→specs index is built once per pass, only flag-on. No
  `lssBlockedMembers` check is needed IN this arm: blocked members are
  INSERTED into the index (blocked=True), so they take the `Just` path
  (`declinedBlocked`) and never reach `Nothing`.
- **Kernel-alias routing:** `OriginGlobal` whose target global aliases a
  kernel cannot be distinguished post-mono without `toptNodes` — it is NOT
  excluded structurally; §1's argument covers it (no post-GlobalOpt
  inliner), and the §4.2 cons-alias fixture pins it.
- **Soundness envelope:** LSS_005 (annotations/dispatch tiers move,
  observable behavior never); LSS_015's var-drop clause; zero-capture
  argument per §1. No representative premise is created — the rewrite
  targets a SPEC, not an instance stamp, so the LSS_024 fence is not
  involved.
- **Census wiring:** `abiStats` gains the three counters (flat — 
  AbiCloningStats is not near the 32-slot cap).

## §4 Phases past the census (contingent)

1. **Substrate:** flag + rewrite; flag-off byte-identity (two binaries /
   one frozen corpus — every compiler edit moves the corpus; re-run BOTH
   arms after the last edit).
2. **Pins:** AbiCloning unit tests — admissible site rewritten to the
   layout-matching spec; `specs == 0` declines; under/over-arity declines;
   blocked member declines; determinism ×2 (two cold flag-on self-compiles
   byte-identical). E2E: a two-site fixture (one admissible, one
   arity-missed) + the cons-alias fixture (`cons = Elm.Kernel.List.cons`
   passed as a value and called saturated — flag-on must not produce a
   CGEN_038 signature mismatch). `--target full` both arms, elm-tests.
3. **Measurement:** lss-opt A/B (wall FLAT band ≥3%, majors reported) +
   runtime-calls acceptance: same-tree counters-lowered legs, flag off/on;
   the census PREDICTS the recoverable events (Phase-0 table); the runtime
   leg must confirm ≥ an agreed fraction set when the table exists (the
   LSS_024 §6.2 ≥85% device). `sat+fast` invariance is the sanity rail —
   a devirted site REMOVES sat events (the Run-H/I "devirt signature":
   sat falls, fast unchanged), so here the rail is total-events
   accounting, not sat+fast constancy.
4. Flip decision recorded separately, never coupled with anything else.

## §4.R Execution record (2026-08-22, all gates and measurements)

Substrate as §3, landed in one day. `AbiCloningStats` gains
`devirtPostFn`/`devirtPostCtor`/`devirtPostNoSpec`; the empty-index early
exit is widened to `Dict.isEmpty index && not postSettle` (a flag-on graph
with devirtable singletons and no closures must still walk — pinned).
Bookkeeping audit (§5.2) closed: `MonoInlineSimplify` clears
`callEdges`/`specValueUsed` BEFORE GlobalOpt and `CsePurity` documents all
three mono-time side tables as dead there — no stale consumer exists.

**Gates (all green):**

- Unit pins: `PostSettleDevirtTest` 6/6 — g rewrite (graph-level callee
  check, not counter-only), c rewrite, under-application decline,
  noSpec decline (+ the historical `declinedNoInstance` still bumps),
  flag-off inertness (with a dummy instance forcing the REAL walk past
  the early exit), minimum-SpecId determinism.
- elm-tests: **13,192 passed / 12 failed** — the recorded pre-existing
  set exactly (13,186 + the 6 new pins).
- Flag-off byte-identity: pre-change binary vs new binary, one frozen
  corpus (the E9.5-bearing tree), both flag-off — `out.mlir`
  **byte-identical** (13,827,927 B), decline counters identical to the
  digit (`declinedNoInstance = 1,390` both).
- Determinism: two cold flag-on self-compiles **byte-identical**
  (13,830,780 B).
- Bootstrap: the ninja chain's Stage-4b JS fixed point held on the
  E9.5-bearing tree (build green end-to-end).
- E2E: **1,686/1,686 PASSED on BOTH arms** — the default arm via
  `--target full` (clean rebuild + JIT suite) and the
  `ECO_MONO_LSS_DEVIRT_POST=1` arm via `run-tests` with
  `build/test/*/eco-stuff` purged (the fresh-cache-per-leg standard).

**Measurement (benchmarks/lss-opt.md Run AE — native binary self-compile,
one cold leg per arm, same tree):**

| arm | wall | max RSS (kB) | minor GC | major GC | promoted | GC/Alloc (s) | out.mlir (B) |
|---|---|---|---|---|---|---|---|
| flag OFF | 5:50.28 | 6,109,400 | 1,461 | 14 | 485,955,839 (14,351 MiB) | 125.13 | 13,827,927 |
| flag ON | 5:52.18 | 6,104,104 | **1,461** | **14** | 486,338,488 (14,367 MiB) | 126.14 | 13,830,780 |

- **Reach acceptance: EXACT.** `devirtPost(fn/ctor/noSpec) = 86/311/0` —
  the §2.R census's admissible table to the digit; `declinedNoInstance`
  1,390 → 993 = −397 = every admissible site captured, none missed, no
  layout misses.
- **Neutrality acceptance: EXACT where it matters.** Minor and major GC
  counts IDENTICAL across arms (the deterministic counters, judged
  first); wall +0.5% and GC time +0.8% — deep inside the FLAT band;
  artifact +2,853 B (+0.02%, the rewritten callee refs).
- Self-compile dispatch heat was known ≈0 in advance (§2.R.2); no
  runtime-calls event-recovery leg is claimed or required under the
  reach criterion.

**Flip status:** DEFAULT-OFF at landing, per §3. The flip is its own
recorded decision (full battery incl. bootstrap fixed points, the repo
standard) — on this evidence there is no self-compile reason to hurry it,
and the reach benefit accrues to any workload the moment the flag is set.

## §5 Risks

1. **Spec-choice divergence** — refuted for zero-capture targets (§1); the
   risk survives only if a `g|` singleton can name a CAPTURING value, which
   would be an LSS_002/LSS_013 honesty violation upstream — pinned by the
   fixture, and any counterexample is a bug in the member discipline, not
   in this rewrite.
2. **Stale bookkeeping consumers** — `callEdges`/`specValueUsed` are built
   at mono time; the rewrite adds a call edge and a `MonoVarGlobal` read
   they do not record. Audit their post-GlobalOpt consumers before landing
   (Prune already ran; Borrow reads callee exprs directly; CafDedupe —
   check). Fail the audit → thread updates or gate the pass earlier.
3. **ABI mismatch between site type and spec type** — eqLayout guarantees
   layout equality; the `MonoVarGlobal` carries the SITE type (the
   translate-time precedent), so call ABI derives from the same types the
   args were built with.
4. **Population double-think** — sites already devirted by translate-time
   E9.1 do not reach the noInstance arm (Run I: noInstance fell 3,023 as
   devirtDirect rose 4,003); if the census contradicts this, stop and
   re-derive.

## §6 Non-goals (recorded)

- The `declinedShape arity-over = 7,371` population — lambda members with
  instances, E2/E2.7 (LSS_011/LSS_014) territory, not `g|`.
- Under-application (M2) PAP-form rewriting — needs a direct PAP-create
  primitive; record the row, build nothing.
- Inlining the devirted calls (a post-GlobalOpt inline pass) — out of
  scope; would re-open the E9.1 freshening-seam class.
- Translate-side arity/annotation widening of E9.1 itself — only if the
  census shows the mass is `specs == 0` layout-misses (then a follow-up
  plan, not this one).
- No flag default changes inside this plan.

## §7 Invariants delta (as landed 2026-08-22)

- **NEW LSS_025** (invariants.csv): the post-settle devirt licence —
  singleton g|/c| noInstance site, plain-var callee, EXACT arity
  (zero-capture proof), minimum-SpecId eqLayout spec, flag-gated; the
  "no post-GlobalOpt inliner" premise recorded on the row (any future
  post-GlobalOpt inline pass must re-open the CGEN_038 kernel-alias
  argument). Pinned by PostSettleDevirtTest (6 pins incl. the graph-level
  rewrite check and minimum-SpecId determinism).
- LSS_015 unchanged (its var-drop clause is cited, not amended).
- `plans/lss-dispatch-value-extraction.md` §11.6 (E10): the fn-global half
  is CLOSED by this landing (mechanism built; self-compile heat measured
  ≈0.24% upper bound in §2.R and accepted as immaterial — the build is a
  reach-completeness decision); the kernel half keeps §2.R.3's warm lead
  (cons-class ≈0.56% + 30 named sites) as its Phase-0 seed.

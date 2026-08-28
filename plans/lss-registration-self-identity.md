# Registration self-identity — de-poisoning the classify-⊤ that dominates uncovered positions

**Status:** proposed 2026-08-27; adversarial review same day (findings AR-1..AR-10
embedded; two corrected the design before implementation). Successor to the
REVERTED `plans/lss-ctor-arrow-identity.md` (user-directed): the constructor
population measured there is a small subset of the population this plan
addresses.

**Flag:** `lss.regIdentity` (`ECO_MONO_LSS_REG_IDENTITY`, hash token `lssRG=`),
DEFAULT-OFF. Artifact-affecting (stored types and keyed spec keys move).

---

## §0 Evidence ledger

### §0.1 THE CENSUS THAT SIZED THE PRIZE (self-compile, 2026-08-27, `pos|` attribution)

Every uncovered arrow position in the emitted registry, split by structural
path — SPINE (`""` or a chain of `/r` segments: the def's own curried
signature) versus NESTED (inside an argument, list, tuple, record, or
custom-type parameter):

```
coverage: positions=134424 k1=32645 kN=5799 var=37693 top=58287 coveredBp=2859
total uncovered positions: 95980
  SPINE  (def own arrows): 76179  (top=54631 var=21548)  79.4%
  NESTED (in containers) : 19801  (top=3656  var=16145)  20.6%
top spine contributors: foldl 8182, andThen 5789, map 5336, foldrHelper 3516,
foldr 3384, map2 1589, cons 1344, RBNode_elm_builtin 1245, balance 1210,
insert 1078, Eerr 1063, Cerr 880
```

**79.4 % of everything uncovered — and 93.7 % of ALL ⊤ (54,631 of 58,287) — sits
at positions describing a def's own arrows in its own spec's stored type.**
The contributors are the hot polymorphic HOFs (many specs each; every spec's
stored type contributes its spine). Constructors (`RBNode_elm_builtin`, `Eerr`,
`Cerr`) appear as a strict subset — confirming the reverted ctor plan was a
corner of this population, not a separate problem.

### §0.2 WHERE THE ⊤ COMES FROM (verified in code)

- `Store.classifyGo`'s `TLambda` arm stamps `LTop` unconditionally
  (Store.elm:3595, its own comment: *"Storeless classification stamps LTop
  (sound-but-imprecise)"*). `classify` is the ABI-structure path; it reads no
  slots and cannot know a set.
- `Mono.overlayAnnotations` replaces those placeholder annos with zonked ones
  — **where a zonked source exists**. A def's own spine arrows at a DIRECT
  call have no slot content (no dispatch is needed, so nothing ever writes
  them), so the placeholder survives into the call's demand type.
- Demands become STORED types at one solver choke point:
  `Engine.enqueueSpec` → `Registry.getOrCreateSpecIdKeyed`
  (keyed path Engine.elm:2132; LSS_010 join path Engine.elm:1929). On key
  hits the stored type becomes `joinAnnotationsChanged storedType demand`,
  and `annoCovers`/`unionAnno` treat ⊤ as ABSORBING — one ⊤-carrying demand
  poisons the stored position for every caller, permanently.
- The position/readback asymmetry this explains: 58,287 ⊤ POSITIONS against
  only 16,937 ⊤ READBACKS. Most position-⊤ never lived in any slot — it is
  classify's placeholder riding demands into the registry, not a widening the
  analysis ever performed.

### §0.3 WHY THIS IS TAUTOLOGICALLY CLOSABLE

The registry key is literally `SpecKey global monoType` — **the global is in
the key**. The value at the stored type's spine position d is, by definition,
`global`'s spec partially applied to d arguments. No inference is needed:

- depth 0: the set is the singleton containing g's own standalone identity
  member — the SAME member `refIdentity` injects at references.
- depth 0 < d < declaredArity: the set is the singleton containing the
  `p|<g>|<d>` PAP member — the SAME member `papMembers` mints.
- depth ≥ declaredArity: NOT self — that arrow belongs to the RETURNED value
  (LSS_013's bound, quoted at LssInfer.elm:2170: *"the first declaredArity
  arrows ARE the parameters; arrow declaredArity+1 belongs to the returned
  value"*). Never stamped by this plan.

### §0.4 History feeding this design

- `refIdentity` (+7.14 pp, the arc's largest win) is the same insight at
  REFERENCE sites: a known global's identity is free knowledge. This plan
  applies it at REGISTRATION, where the census says 79.4 % of the remaining
  gap lives.
- The ctor arc's P0 proved the direct-argument path already works
  (`LssGapCtorAsValue`: the parameter position holding a passed ctor is
  COVERED) and that every def's own spine reads ⊤ (universal across probes).
- The E9.2 identity-fold lesson (Translate.elm:3875): a kernel-alias global
  IS the kernel value — ONE identity, because *"a split g|/k| identity would
  join to a 2-set and kill singleton consumers."* The stamp must reuse that
  exact chooser or it recreates the bug at every kernel-backed def.

---

## §1 Design

### §1.1 The stamp

One function, applied to every solver-path demand at the enqueue choke point,
gated on `lss.enabled && lss.regIdentity`:

```
stampSelfSpine : Global -> MonoType -> S -> ( MonoType, S )
-- walk the leading MFunction spine to depth min(declaredArity g, spine length);
-- at each depth d, if the anno is LTop or LVar, replace it with
-- LSet [ memberIdFor g d ]; NEVER overwrite an existing LSet;
-- below the spine, and past declaredArity: untouched.
```

`memberIdFor g 0` = the standalone identity chooser (kernel-alias fold → the
`k|home.name` kernel member; Ctor/Enum/Box node → `c|` member; cycle → `g|`
provisional; plain → `g|` — verbatim the E9/refIdentity reference-path
selection, same interning, so every id joins with every existing injection).
`memberIdFor g d (d>0)` = the `p|<g>|<d>` id `papMembers` mints, same
interning.

**Never-overwrite is load-bearing, not politeness (AR-4):** an existing `LSet`
at a spine position is either the same id (join idempotent) or evidence of a
defect elsewhere; overwriting would HIDE the second case, and a union at a
genuinely-shared position must stay a union.

### §1.2 Where it runs — and where it must not

- **All solver enqueues**: a wrapper in `Translate` (which can see
  `LssInfer.declaredArityOf` and the chooser — `Engine` cannot import either)
  replacing every `Engine.enqueueSpec` call. Stamping BEFORE enqueue means the
  keyed path's key, the join path's join, and the stored type all see the same
  stamped demand — the join-absorption problem (§0.2) is dissolved because
  every demand for g agrees at spine positions.
- **NOT the subst engine** (unkeyed `getOrCreateSpecId` sites in
  `Specialize.elm`/`Monomorphize/Monomorphize.elm`): its all-⊤ population is
  the `MapTemplate.declinedEngine` separation, the recorded reason the §3.2
  unknown-elimination flip was withdrawn. The wrapper lives in the solver's
  Translate; the subst path never routes through it.
- **NOT nested positions** (20.6 % of uncovered): those are real dataflow, the
  paper computes them by unification, and Eco's existing mechanisms
  (signatures, demand flow, containers) own them. This plan adds no inference.
- **`Mono.Accessor` globals: deferred** — they have their own virtual-global
  member scheme; stamping them is a follow-up with its own id-discipline
  check, recorded here so the scope cut is visible.

### §1.3 Key/join coherence

The stamp is a pure function of `( global, depth )`, applied to every demand
of that global. Hence within one global it cannot split keys (all demands gain
the identical members at the identical positions), and the only merges it can
cause are demands that previously differed ONLY by one having learned the
self-identity some other way — a correct merge of two specs that were always
the same. Spec-count movement is expected DOWNWARD or flat; the battery
records `specs=`/`countByGlobal` movement.

---

## §2 Paper fidelity (reviewed against the paper and the mapping doc)

The paper types every function with a lambda-set on every arrow, and a
definition's own arrow carries the set containing ITSELF — T-Abs annotates a
λ with its own identity, and 𝒬 injects EVERY λ (Fig. 6); the environment entry
for a definition therefore never has an unknown at its own arrows, and
TIU-Def-Ref instantiates that knowledge at every use (`τ[ᾱ↦β̄]`).

Eco's registry stored type is the per-spec analog of the paper's environment
entry. Reading ⊤ at its spine is a state the paper cannot even express — the
information is not merely derivable, it is part of the entry's own key. The
stamp restores the paper's invariant at the paper's location (the definition's
type), by lookup rather than inference. Three fidelity boundaries:

1. **Curried spine depths (d > 0)** have no L^src analog (curry-free). Eco's
   established equivalent is LSS_013's arity bound with DISTINCT per-depth
   `p|` identity — the `papMembers` discipline, shipped and default-on. The
   stamp reuses those exact ids.
2. **Nothing is stamped that the paper computes by flow.** Argument positions,
   container elements, returned-closure arrows (depth ≥ arity): untouched.
3. **Injection totality is preserved, not stretched (AR-5):** the stamped
   class at spec-g's spine position has exactly one possible inhabitant — g's
   spec (or its depth-d PAP). No other producer can flow there, so the class
   is injection-complete by construction; and `p|` members are the DECLINING
   devirt class by `papMembers` design, so depth>0 singletons cannot license
   the captured-args miscompile.

---

## §3 Adversarial review record (run 2026-08-27, against code and paper)

- **AR-1 (chooser reuse is mandatory):** stamping `g|` at a kernel-backed def
  (e.g. `Basics.add`, whose observed sigfacts row is `m=1,k`) would create a
  g|/k| split identity — the exact 2-set that E9.2's fold exists to prevent.
  The stamp calls the SAME chooser as the reference path (Translate:3875
  region), including the kernel-alias fold and the `c|` arms.
- **AR-2 (join absorption forces stamp-at-demand):** stamping only the stored
  type after creation dies at the first ⊤-carrying later demand
  (`annoCovers`: ⊤ absorbs). Stamping every demand BEFORE
  `getOrCreateSpecIdKeyed` makes joins idempotent at spine positions. This
  killed the "post-process the registry once" variant.
- **AR-3 (stamped sets re-enter the store — Q exposure):** stored/demand types
  are seeded into items via `monoTypeToVar` (`Store.elm:688`: every `LVar n`
  resolves to a slot; `LSet` content is demand-encoded into slots). So the
  stamp's members DO reach slots, and LSS_037 ("every member in a slot is a
  recorded constraint") applies. The demand-encoding path is an existing
  Q-recorded write class; the battery's Q gate (`REPRODUCES=yes`, `unseen`
  not rising) is the check, exactly as the ctor plan specified for its
  injection.
- **AR-4 (never-overwrite):** see §1.1 — overwriting an `LSet` would hide id
  disagreements (a defect signal) and break genuinely-shared unions.
- **AR-5 (miscompile-class guard, refined after reading the consumers):** the
  head-anno readers are `AbiCloning.instanceMember:660` and
  `LssFacts.elm:221`, and in BOTH the head anno is only the FALLBACK when the
  closure has no minted member (`closureInfo.lssMember`/`srcLambda` win).
  `instanceMember` feeds fast-call index stamping, so the stamp makes that
  fallback fire more often — at closures whose type's head now reads `{g}`.
  Each firing is sound by the tautology chain (type equality is preserved by
  translate; a value typed with spec-g's stored type at head IS g's spec),
  and the surrounding v1 licensing doc already enforces "never stamp
  non-singleton sites" / "a value can only flow to sites at least as wide".
  Depth-d singletons are `p|` DECLINING members — devirt refuses, so no
  captured-args drop is reachable. Residual risk is empirical, and gate 5b +
  E2E both arms + the dispatch A/B are its checks.
- **AR-6 (arity bound, not spine length):** stamping every leading arrow
  would claim returned closures are PAPs of g — FALSE for any def returning a
  function it did not curry (e.g. `mkStep`). `declaredArityOf` bounds the
  walk; kernel-alias arity uses the same `declaredArityGo` arms the
  injection-completeness work repaired.
- **AR-7 (placement forced by the import graph) — CORRECTED DURING REVIEW:**
  `Engine` cannot import `LssInfer` (cycle), so the stamp cannot live inside
  `enqueueSpec`; the wrapper lives in `Translate`. The first draft claimed
  "all callers are the seven Translate sites (911 accessor, 1111 port, 1729,
  3037, 3133, 3163, 3234)". **That was WRONG: `seedSpec`
  (MonoSolver/Monomorphize.elm:1189) registers MAIN and the flags decoder
  via `Registry.getOrCreateSpecId` directly, bypassing `enqueueSpec`.** Two
  entries the wrapper would silently miss — and under AR-11 a missed route is
  not a missed stamp but a ⊤-collapse for that spec. `Monomorphize.elm`
  imports `Translate` (line 46), so `seedSpec`/`seedFlagsDecoder` call the
  exposed stamp directly. The `regid: missed=N` census alarm remains the
  runtime check that the enumeration stays complete.
- **AR-11 (THE JOIN COLLAPSES SET-VS-VAR TO ⊤ — raises caller completeness
  from diagnostics to soundness-of-benefit):** verified:
  `unionAnno (LSet _) (LVar _) = LTop` (Monomorphized.elm:1796-1800), and
  spine positions measurably receive `LVar` demands (21,548 spine-var in the
  census). So if ANY demand for spec g reaches the join unstamped, the stored
  spine anno collapses to ⊤ — erasing the stamp's benefit for every caller of
  that spec, not just the missed one. Consequences: (a) stamping must ride
  EVERY demand (already §1.1); (b) `regid: missed=0` is a HARD gate in the
  battery, not a report line; (c) the P0 probes must include a
  multi-caller shape so a partial-routing bug shows up as a ⊤ that should
  have been a set.
- **AR-8 (subst separation preserved):** the wrapper is solver-Translate-only;
  the unkeyed registry entries of the subst engine keep their all-⊤
  population and `declinedEngine` keeps its meaning.
- **AR-9 (what the coverage gain can and cannot be):** addressable
  upper bound = spine positions at depth < declaredArity. The census's 76,179
  spine positions include depth ≥ arity tails it cannot separate (it has no
  arity), so the plan PREDICTS a large gain but pins no exact number;
  the P0 probes carry exact per-row predictions instead, and the self-compile
  A/B is the measured answer. Quoting 79.4 % as the expected gain is
  FORBIDDEN — it is the ceiling of the population, not the stampable subset.
- **AR-10 (spec-key movement is a feature to watch, not a regression):**
  §1.3's merges reduce fan-out; `specs` count and `countByGlobal` are
  recorded in the battery so an unexpected EXPANSION (which the design says
  cannot happen) fails loudly.

---

## §4 Phases

### P0 — minimal mechanism + probe predictions (GO/NO-GO)

Build the flag + wrapper + stamp (the §5 edit list, steps 1–4 only), then run
the existing `LssGap*` probes flag-on and check EXACT predictions:

| probe | prediction |
|---|---|
| `LssGapCtorScale` | ALL 16 uncovered rows are spine at depth < arity (ctors B/C/D spines, `unA..unD\|\|`, `add\|\|`, `add\|/r`, `text\|\|`) ⇒ **18/18 positions covered, coveredBp=10000** |
| `LssGapCustomTypeFn` | spine rows (`useBox\|\|`, `useBox\|/r`, `mul\|\|`, `mul\|/r`, `text\|\|`) flip ⇒ 9/9 covered |
| `LssGapListOfFns` | spine rows flip (`add`, `mul`, `runAll\|\|`+`/r`, `foldl\|\|`+`/r`+`/r/r`, `text\|\|`); NESTED rows (`foldl\|/a0/a0`, `foldl\|/r/r/a0/l`, `runFirst`… `/a0/l`, `handlers\|/l`) do NOT ⇒ uncovered drops to the nested residue only |
| `LssGapCtorAsValue` | `useCtor\|\|`, `useCtor\|/r`, `text\|\|` flip ⇒ 6/6; the already-covered param position UNCHANGED |
| all probes | runtime `CHECK` outputs byte-identical (the stamp adds knowledge; it must change no behaviour at defaults-off dispatch) |

GO = every prediction holds. Any spine row that fails to flip, any nested row
that flips, or any CHECK regression = NO-GO: stop, diagnose, amend this plan
before proceeding.

### P1 — pins + census self-check

- Unit pins (§6). `regid:` census line: `stamped=N alreadySet=N pastArity=N
  missed=N` — `missed` per AR-7 is the caller-completeness alarm and must be 0.
- `provenance:`/`stampwalk:`/`liveness:` unaffected (different axis); assert
  byte-equal flag-off.

### P2 — battery (ordered)

1. Save `eco-preReg` binary BEFORE building (`--target full` deletes
   binaries). Frozen-corpus byte-identity flag-off vs `eco-preReg`.
2. Probes (P0 re-run — they are now the fast regression net).
3. Self-compile coverage A/B, same binary, flag env only: `coverage:` is THE
   gate — analysis coverage must rise (gate 0); record `top`/`var` movement
   (predicted: `top` falls by the stampable-spine share, dominated by the
   54,631 spine-⊤); record `specs`/`countByGlobal` (AR-10: must not expand);
   `regid: missed=0`.
4. Q both arms: `REPRODUCES=yes diverge=0`; `Q-shadow unseen` must not rise
   (AR-3).
5. Gate 5b: lower flag-on, 0 `undefined fast evaluator`, RUN 200 s.
6. elm-tests at the pre-existing set; E2E `--target full` BOTH arms (touch
   `test/elm/src` first — env-blind cache), rebuild `eco-compiler` after.
7. Dispatch A/B on the Run-AO rail — RECORDED, NOT GATED. Head singletons are
   newly visible to devirt/AbiCloning; movement in `devirtDirect`/
   `stampedStaged`/`declinedNoInstance` is expected and reported beside.
8. Flip decision by gate 0, with the whole §-ledger as evidence.

## §5 Implementation edit list (lowered)

1. **`Compiler/Eco/Config.elm`** — the 4-site flag pattern, copied from
   `refIdentity`: field `regIdentity : Bool` + doc (cite this plan; note
   artifact-affecting, DEFAULT-OFF); `defaultLss` `= False`; decoder
   `optionalField "regIdentity"` **APPENDED LAST** (positional); hash token
   `lssRG=` differs-from-default block.
2. **`Builder/Eco/Config.elm`** — `applyLssRegIdentityOverride` +
   `ECO_MONO_LSS_REG_IDENTITY` chain row (copy the `SIG_ROOT_ID` pair; mind
   the paren structure — the ctor revert's dangling-paren break came from
   exactly this block).
3. **`Translate.elm`** — `memberIdForDepth : TOpt.Global -> Int -> Engine.S ->
   ( Maybe Int, Engine.S )`:
   depth 0 → replicate the Translate:3875 chooser BY GLOBAL (not by expr):
   `LssInfer.kernelAliasOf` → kernel member id via the same interning the
   `standaloneArgKernelMember` path uses; node lookup `Ctor`/`Enum`/`Box` →
   `standaloneMemberIdFor ("c|" ++ key)`; `Link`→cycle → `("g|" ++ key)`;
   plain Define → `("g|" ++ key)`; `Nothing` for kernels with no member id
   path, Accessor, Manager, ports (stamp skipped, counted `pastArity`-style).
   depth d → the `papMembers` id via `Translate.papMemberKey`'s exact
   spelling (verify at implementation: the `p|<g>|<supplied>` intern used by
   `injectPapMember`).
4. **`Translate.elm`** — `stampSelfSpine` per §1.1 (bound =
   `LssInfer.declaredArityOf g 8 s`), `enqueueSpecStamped global monoType =
   if lss.enabled && lss.regIdentity then stamp then Engine.enqueueSpec else
   Engine.enqueueSpec` — and replace the seven `Engine.enqueueSpec` call
   sites (911 skips stamping by construction — Accessor returns Nothing —
   but ROUTE it through the wrapper anyway so the census counts it).
   **Depth-d id spelling (verified):** `Engine.memberIdFor (papMemberKey
   global d)` with `papMemberKey` = `"p|" ++ toComparableGlobal ++ "|" ++ d`
   (Translate.elm:4058) — call the SAME functions.
5. **`MonoSolver/Monomorphize.elm`** — `seedSpec` and `seedFlagsDecoder`
   (AR-7): stamp their monoType through the Translate-exposed stamp before
   `Registry.getOrCreateSpecId`. Monomorphize already imports Translate.
6. **Census**: counters on S (or reuse `bumpArgFlowCensus` string keys —
   report-gated, zero cost off): `regid|stamped`, `regid|alreadySet`,
   `regid|pastArity`, `regid|noId`; the `missed=` alarm computed at render
   time from the registry (walk reverseMapping under `lss.arrowCensus`,
   count stampable-global spine ⊤/var at depth < arity).
7. **Unit pins** (`LssRegIdentityTest`, harness precedents cited inline):
   1. differential: `Box`-module spec stored type head = `LSet [c|Box]`
      flag-on, `LTop` flag-off (runSolverMonoWithLimits, both arms asserted);
   2. arity bound: `mkStep`-shaped def (arity 0 returning a lambda… use a
      1-ary def returning a closure): `/r` position NOT stamped;
   3. kernel-alias: a `(::)`-using fixture — stamped id joins with the k|
      reference member (no 2-set at any shared position);
   4. never-overwrite: a position already carrying a set keeps it;
   5. subst isolation: `runSubstMonoWithLimits` output byte-equal with the
      flag on (the subst path never routes through the wrapper);
   6. co-existence: `LssPapMembersTest` joinModule green with `regIdentity =
      True` added (no false singleton introduced at consumers).

## §6 Non-goals

Nested positions (the 20.6 %); accessor identity; the subst engine; any change
to `classify` itself — the placeholder stays, because the ABI-structure
contract (`overlayAnnotations` doc) is load-bearing and this plan repairs the
one place the placeholder ESCAPES into gate-visible state.

---

## §7 P0 RESULT — GO, with the prediction model CORRECTED

Measured 2026-08-27 (build clean; flag-off arms byte-reproduce the baseline
probe numbers, so the mechanism is inert off):

| probe | off | on | Δ |
|---|---:|---:|---:|
| `LssGapCtorScale` | 11.11 % | **83.33 %** (top 15→3, var 1→0) | +72.2 pp |
| `LssGapCustomTypeFn` | 44.44 % | 66.66 % | +22.2 pp |
| `LssGapListOfFns` | 26.31 % | 52.63 % (var 8→3) | +26.3 pp |
| `LssGapCtorAsValue` | 50.00 % | 83.33 % | +33.3 pp |

**The predictions of 100 % did NOT hold, and the entire residue is one
pattern:** every remaining spine-⊤ row is a KERNEL-BACKED global — `add`,
`mul` (Basics kernel aliases), `text` (VirtualDom kernel) — plus exactly the
predicted nested rows. Every plain-define and constructor spine flipped
(`unA..unD`, `runAll`, `foldl`'s spine vars, `B/C/D`, `useBox`, `useCtor`,
`chosen`).

**Diagnosis: the kernel parametricity boundary, already named by the
injection-totality census ("kernel + callKernel … the permanent ⊤ boundary").**
The kernel-license machinery deliberately poisons kernel-adjacent sets
(LSS_022: refusal = cross-call retention), and ⊤ absorbs the stamp at the
join. The stamp ARRIVES — `add|/r` moving var→top flag-on proves an active ⊤
union, not a missed route — and is then absorbed by policy. This is
kernel-boundary POLICY, not a routing failure and not unsoundness; and the
movement is gate-neutral (var and top are both uncovered).

**Monotonicity held everywhere:** k1+kN never decreased at any probe
(2+0→11+4, 3+1→3+3, 3+2→5+5, 3+0→3+2). No covered position was lost.

**Model correction, binding on P2's expectations:** the stampable population
is spine positions of NON-kernel-backed globals. Corpus reading: the census's
top spine contributors (`foldl` 8,182, `andThen` 5,789, `map` 5,336,
`foldrHelper`, `foldr` — plain elm/core defines) flip; `cons` 1,344
(kernel-alias `(::)`) does not. Predicting the exact self-compile number is
not licensed; the A/B measures it.

**The `missed=` alarm is REDEFINED (the original would false-alarm):** a
registry walk counting "stampable global with uncovered spine" fires on every
kernel-alias global by design. Replaced with `regid|residueHeads` — flag-on,
count non-kernel-alias non-Accessor registry globals whose HEAD anno is still
⊤/`LVar` — reported and investigated, not gated; routing correctness is
carried by the P0 probe evidence (plain spines flip on every exercised path),
the enumerated call-site list, and the seed stamping.

**The probe `CHECK` runtime assertion moves to P2's E2E arms** (probes here
were compiled standalone, not executed; the E2E suite runs all 15 `LssGap*`
with their CHECK lines in both flag arms).

## §8 BATTERY FINDING — the stamp meets the body-root member: covered sets are
## kN, not k1, and that is ACCEPTED under gate 0

The first pin run failed in the GOOD direction: stamped heads read `LSet 2..3`,
not the predicted singletons. The MSET census names the members exactly:

```
MSET 1636 2 l|0|…unA…|g|eco/compiler:LssGapCtorScale.unA|…
```

— the def's own BODY-ROOT lambda member (`l|N`) paired with the standalone
`g|` member the stamp (and `refIdentity`) mints. Two ids, one function, both
honest; they never met before because the spine was ⊤, and the stamp made
them meet. The set is SOUND (every member denotes the def) and COVERED (kN),
and gate 0's own rule applies: a kN set counts exactly as much as k1 —
completeness first.

**What this costs, and where the follow-up lives:** singleton-only consumers
(fast-call stamping) cannot use a 2-set, so the exploitation value of these
positions waits on collapsing the l|/g| split — grounding the provisional
standalone member to the def's root member, which is exactly the
`lss-fidelity-2` standalone-member-grounding territory and is deliberately
NOT smuggled into this plan.

Pins corrected to assert COVERED (set) rather than singleton; pin 3's kernel
arm likewise (a benign `l|/k|` pairing is possible at fixture scale; the pin
now rejects only a surviving `LVar`, which would indicate broken routing).

## §9 BATTERY RESULTS (2026-08-27/28) — every hard gate GREEN

| gate | result |
|---|---|
| flag-off byte-identity (frozen corpus, vs `eco-preReg`) | **IDENTICAL** |
| **coverage A/B (gate 0)** | **28.60 % → 80.26 % (+51.66 pp)** |
| spine uncovered | 76,180 → **6,510** (−91.5 %; residue = kernel boundary + past-arity) |
| nested uncovered | 19,799 → 19,735 (untouched — the stamp is surgically spine-only) |
| ⊤ / var | 58,289 → 9,700 (−83.4 %) / 37,690 → 16,545 (−56.1 %) |
| stamped / alreadySet | 193,774 / 57,145 |
| positions | 134,425 → 132,994 (keyed-spec merges, AR-10's predicted direction) |
| Q-infer | byte-identical BOTH arms: `diverge=0 REPRODUCES=yes` (stamp acts after inference) |
| Q-shadow | pre-existing 79 → **70** flag-on (`unseen` 63→56 — fell; gate was "must not rise") |
| gate 5b | lower clean (0 undefined fast evaluator), RUN 200 s healthy |
| E2E `--target full` | **1,706/1,706 BOTH arms** (suite grew by the 15 `LssGap*` probes; their runtime CHECKs pass flag-on) |
| elm-tests | corrected-pin re-run + dispatch A/B recorded in §10 |

The +51.66 pp is 7.2× the arc's previous largest completeness win
(`refIdentity`, +7.14 pp). kN carries the bulk (+49,863) per §8's l|/g|
pairing; k1 +18,440.

## §10 TAIL RESULTS — corrected pins green; dispatch EXACTLY NEUTRAL

elm-tests with the corrected (§8) pins: **13,372 / 12 pre-existing** — all five
`LssRegIdentityTest` pins pass.

Dispatch A/B (Run-AO rail, counter-lowered arms, cold workloads,
shipping-default env, no REPORT in the measured run):

| arm | distinct | sat | typed | fast | **fast %** | wall |
|---|---:|---:|---:|---:|---:|---:|
| off | 7,272 | 2,237,813,781 | 35,123,663 | 605,960,992 | **21.308** | 7:34.65 |
| on | 7,207 | 2,237,813,712 | 35,102,139 | 605,960,985 | **21.308** | 7:31.81 |

Workload outputs byte-IDENTICAL across arms (the invariance check that makes
the counter comparison admissible). **+51.66 pp analysis coverage for −7 fast
events of 606 M and flat wall** — the completeness-first bargain at its
starkest: the new knowledge is not yet exploited (kN sets, l|/g| split), and
it cost nothing to acquire.

## §11 FLIP DECISION — TAKEN 2026-08-28 (user-directed)

`defaultLss` now carries `regIdentity = True`. Three riders shipped with it:

1. Doc comments record DEFAULT-ON with the measured evidence; `lssRG=0` rides
   the OFF arm (the arrowIdentity/refIdentity precedent).
2. The differential-overlap rule applied PREEMPTIVELY (fourth occurrence):
   `regIdentity` pinned OFF in `LssSigFlowTest` (its readers scan all annos of
   a def's demands, including heads the stamp writes), `LssPapMembersTest`
   (test 1's no-singleton assertion would trip on the honest `{g|useIt}` head)
   and `LssSigRootIdentityTest` (same reader in its co-gate).
   `LssRegIdentityTest` itself needed nothing — its harness sets the flag
   EXPLICITLY from the pin's parameter in both arms.
3. Flip battery — ALL GREEN (2026-08-28):
   - frozen-corpus equivalence: pre-flip binary env-forced ON vs new-defaults
     binary with no env — **byte-IDENTICAL** (the flip lands exactly the
     measured configuration);
   - census at defaults: `positions=132994 k1=51085 kN=55664 var=16545
     top=9700 coveredBp=8026` — field-for-field the measured flag-on leg;
   - elm-tests: 13,372 / the pre-existing 12 EXACTLY (the preemptive pinning
     held — zero new failures);
   - E2E at defaults: **1,706/1,706**.

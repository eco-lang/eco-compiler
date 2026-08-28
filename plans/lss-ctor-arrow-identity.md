# Constructor arrow identity + declaration-site injection — closing the ctor half of the provenance gap

**Status:** proposed 2026-08-27, adversarially reviewed same day (findings AR-1..AR-9
embedded below — two of them CORRECTED the original design before a line was
written). Follows `plans/lss-provenance-ratio-census.md` §9.6, which traced the
mechanism this plan repairs.

**Flags:** `lss.ctorIdentity` (`ECO_MONO_LSS_CTOR_IDENTITY`, hash token
`lssCT=`), DEFAULT-OFF. Effective only under `sigRootIdentity && papMembers`
(both default-on since 2026-08-27) — the consumption path this plan rides is
gated on exactly that conjunction in `Engine.withScratchStore`.

---

## §0 Evidence ledger

### §0.1 MEASURED (probes, 2026-08-27 — `lss-provenance-ratio-census.md` §9.3)

Background `stampwalk: none=122 arrowsNone=218` is identical across eight
structurally different probe programs (`LssGapNoDecls` control sits exactly on
it). Deviations are therefore attributable:

| probe | declares | Δnone | ΔarrowsNone |
|---|---|---:|---:|
| `LssGapEnumNoArrows` (`type Colour = Red\|Green\|Blue`) | zero-arity ctors | 0 | 0 |
| `LssGapCustomTypeFn` (`type Box = Box (Int -> Int)`) | 1 union ctor, arity 1 | +2 | +4 |
| `LssGapRecordNoFn` (`type alias Nums = {a:Int, b:Int}`) | 1 alias ctor, arity 2 | +3 | +6 |
| `LssGapCtorScale` (4 union ctors, arities 1+2+3+4) | 10 ctor arrows | +8 | +20 |

Loss ≈ 2 arrows per union-ctor arrow (two copies), 3 per alias-ctor arrow
(three copies). `LssGapCtorScale` coverage reads `top=15/18` positions — the
ctor-heavy probe is the LEAST covered of the whole set.

### §0.2 VERIFIED IN CODE (all anchors re-read 2026-08-27)

- **Union-ctor birth:** `Compiler/LocalOpt/Typed/Module.elm:147` `addCtorNode`:
  `ctorType = List.foldr Can.tLambda resultType c.args`, materialized TWICE —
  the node `TOpt.Ctor c.index c.numArgs ctorType` (line 162) and the annotation
  `Can.Forall freeVars ctorType` (line 175). `Can.Enum` → `TOpt.Enum` (no
  arrows when arity 0); `Can.Unbox` → `TOpt.Box ctorType`.
- **Alias-ctor birth:** same file, `addAlias`: `funcType = List.foldr
  Can.tLambda fieldType acc` materialized THREE times — Define node meta,
  `TOpt.Function` meta, annotation `Can.Forall freeVars funcType` — plus field
  types repeated in `argNamesWithTypes` and body `VarLocal` metas, all with
  `tvar = Nothing`.
- **`Canonical.elm:358`:** `tLambda = TLambda TypeIds.NoArrow`. Docstring
  invariant: only `Compile.elm` (solver live) and `AssignMVarIds` may name a
  slot.
- **Why stamping cannot reach these:** `Compile.elm` stamps `nodeTypes` and
  `annotations` while the solver state is live; ctor types are synthesized
  AFTERWARDS by the typed optimizer and have no solver variable (the checker
  never inferred "the constructor" as an expression). Confirmed empirically by
  the §8.3.3 guard census: 0 skips among everything that EXISTS at stamp time,
  yet ctor arrows still land in the `none` bucket.
- **Rewrite arms:** `AssignMVarIds.elm` `rewriteNode` has explicit
  `TOpt.Ctor`/`TOpt.Enum`/`TOpt.Box` arms (~lines 547-566), each calling
  `rewriteCanTypeTop ctx canType`. Annotations are rewritten by
  `rewriteAnnotationsByGlobal` (line 419), keyed by `TOpt.Global`, with `nodes`
  in scope in `assignIds` — so ctor-ness of an annotation is decidable by a
  node lookup.
- **Side-table machinery to reuse:** `recordRootKey` (AssignMVarIds:~177):
  takes the already-minted `( arrowId, ctx )`, dedupes via
  `rootKeyEnv : Dict ( String, Int ) Int`, draws from the NEGATIVE
  `nextRootKey` supply, inserts into `arrowRootOf`. Consumption:
  `Store.loadTypeC` translates `occKey → memoKey` through `arrowRootOf` only
  when `arrowKeyRoots` (= `scratchRootKeys` = `sigRootIdentity && papMembers`,
  scratch store only; `isolatedLoadCtx` pins it off — H1).
- **The two copies DO meet in one store:** unit-member resolution
  (`LssInfer.elm:540`) gives a Ctor unit `memberOf global canType Nothing` —
  the NODE copy — while the signature's ordinal source is
  `sigSourceTypeFor` (LssInfer:190), which PREFERS THE ANNOTATION copy.
  Both are loaded through the shared scratch memo during the ctor unit's
  inference; today their arrows are distinct occurrences, so they mint
  disjoint slots.
- **`c|` members exist:** `Engine.standaloneMemberIdFor ("c|" ++ key) g`
  (Engine:1602 doc; minted at LssInfer:1397/1400 and at use sites via
  `standaloneArgMember`, Translate:3890/3893). Interned — the same ctor always
  yields the same member id.

### §0.3 THE HOLE THE REVIEW FOUND IN THE ORIGINAL SKETCH (AR-3)

The sketch was "give the arrows identity at birth, done." **Identity alone is
measurably worthless**, because nothing ever WRITES to a ctor's canonical
slots: the unit member is bodyless (no body inference), and use sites
instantiate the annotation ISOLATED (fresh slots, no write-back — the H1
design, correct and untouched). Tying the node copy to the annotation copy
unifies one empty slot with another empty slot; every signature ordinal still
zonks to allflex and coverage moves by ZERO.

What is missing is the paper's other half: a constructor is a known function,
so the arrow(s) of its declared type carry the singleton set containing the
constructor itself. Eco already knows this at USE sites
(`standaloneArgMember` injects `c|` when a ctor is passed as an argument) but
never at the DECLARATION, so the knowledge is trapped per-use and per-item.
The fix is therefore two coupled phases: **identity** (P1) makes "the ctor's
arrow at ordinal i" a well-defined position shared by signature and unit;
**declaration-site injection** (P2) writes `c|ctor` into those positions, so
the ctor's signature stops being trivial and `applyFacts` delivers the member
to every use. This is precisely the `ppType|0|m=1,gc` mechanism that
`sigRootIdentity` unlocked for ordinary defs, extended to the one producer
class that has no body to learn from.

---

## §1 Paper fidelity — reviewed against the LSS paper, and why this is
## restoration, not extension

The paper (`design_docs/auto-borrow-inference/lambda-set-specialization.pdf`;
mapping doc `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`)
gives every arrow in every type a lambda-set variable, including arrows inside
data-type declarations; `ζ = 𝓔(ξ)` (146:10) ties variables the checker's
unification relates, and TIU-Def-Ref instantiates a definition's scheme with
fresh variables per use (`τ[ᾱ↦β̄]`).

Three fidelity points, adversarially checked:

1. **The declaration is single in the paper; Eco duplicates it.** The paper
   has ONE environment entry for a constructor, whose arrows carry quantified
   set variables. Eco's typed optimizer materializes that entry two (union) or
   three (alias) times, each copy minting independent arrow identity. The
   copies co-refer in the paper trivially — there is only one. P1's canonical
   identity CANCELS an Eco implementation artifact; it does not merge anything
   the paper keeps distinct. Per-use instantiation freshness (the paper's β̄)
   is preserved untouched: isolated loads still pin `arrowKeyRoots = False`.

2. **The constructor's own set is not inferred in the paper — it is given.**
   A constructor is a literal function of the program, so the set on its
   declared head arrow is the singleton containing it; 𝒬 injects EVERY
   function (Fig. 6), and the recorded `papMembers` lesson is that Eco must
   not leave any producer class uninjected. P2's declaration-site `c|`
   injection is that rule applied to constructors at their declaration rather
   than re-derived at each use. The spine-depth bound (LSS_013: "a PAP of
   member m is m") makes the member sound on all `arity` spine arrows.

3. **What this plan deliberately does NOT do** (and the paper does not
   either): merge across uses (isolated instantiation untouched); give ctor
   PAYLOAD arrows any set they did not receive from flow (the payload arrow of
   `Box : (Int -> Int) -> Box` stays governed by what construction sites flow
   into it — demand types and the keyed registry, the existing mechanism);
   touch translate-side identity (scratch store only, §1 of
   `lss-solver-root-signature-identity.md` still applies).

**Soundness envelope (AR-9).** Root-sharing is sound iff every producer
flowing into a shared class injects a member (the `arrowSolverRoots`
miscompile lesson). The classes this plan creates contain: the ctor's own
`c|` member (P2 injects it — total by construction), plus anything a USE
unifies into an instantiated copy — but instantiated copies are isolated and
never write back, so no external producer ever reaches the canonical class.
The shared class's set is exactly `{c|ctor}` at spine ordinals and whatever
demand flow already writes at payload ordinals. No false singleton is
constructible: a position where "ctor or lambda" flows is a USE-side join of
an instantiated copy with the lambda's slot, unchanged by this plan and
already injection-complete under `papMembers` + `refIdentity` +
`standaloneArgMember`.

---

## §2 Design

### §2.1 P1 — canonical ctor arrow identity (side table, negative keys)

**Scope: union ctors only** (`TOpt.Ctor`, `TOpt.Box`, and vacuously
`TOpt.Enum`). Alias ctors are `TOpt.Define` nodes indistinguishable from user
code at this phase (AR-2) — deferred to P4 with the detection question stated
there, not silently dropped.

Mechanism, mirroring `recordRootKey` exactly:

- `Ctx` gains `ctorScope : Maybe String` (the ctor's canonical key,
  `"c|" ++ TOpt.toComparableGlobal g`). `GlobalMVarState` gains
  `ctorPath : Int` (pre-order arrow counter within the current copy) and
  `arrowsCtorKeyed : Int` (census).
- A wrapper `withCtorScope : String -> Ctx -> (Ctx -> (a, Ctx)) -> (a, Ctx)`
  sets `ctorScope`, RESETS `ctorPath` to 0, runs the rewrite, restores
  `ctorScope = Nothing`. Applied at: the three ctor node arms in
  `rewriteNode`, and in `rewriteAnnotationsByGlobal` when the global's node
  (looked up in `nodes`) is `Ctor`/`Enum`/`Box`.
- In `rewriteCanType`'s `TLambda` arm: while `ctorScope = Just key` and the
  flag is on, EVERY arrow increments `ctorPath` (both arms — AR-6: indices
  must stay structural even if a `SolverRoot` arrow ever interleaved), and the
  `NoArrow` path calls `recordCtorKey key pathIdx (freshArrowId ctx)`, which
  dedupes `( key, pathIdx )` through the EXISTING `rootKeyEnv`, draws from the
  EXISTING negative `nextRootKey` supply, inserts into `arrowRootOf`, and
  bumps `arrowsStamped` (AR-4: the stampwalk census classifies
  identity-carrying arrows via that counter; without the bump its
  `RECONCILES` self-check goes `NO` the moment this flag turns on) and
  `arrowsCtorKeyed`.
- A `SolverRoot` slot inside ctor scope keeps its solver behaviour (real 𝓔
  wins; today unreachable since ctor types are all-`NoArrow`, but the arm is
  written defensively).

**Why the two copies land on the same keys with a plain counter:** for union
ctors both copies ARE the same `ctorType` value (built once in `addCtorNode`,
used twice), so pre-order traversal yields identical index sequences. This is
pinned by unit test, not assumed (§5 pin 1).

**Key-space safety (AR-5):** `rootKeyEnv` is keyed `( String, Int )` where
existing entries use a MODULE key (`author/project:Module`,
ModuleName.elm:247). Neither package names nor Elm identifiers can contain
`"|"`, so the `"c|…"` namespace cannot collide. Verified at both format
definitions; pinned anyway (§5 pin 4).

**Byte-identity argument:** identical to `sigRootIdentity` P1 — occurrence-id
minting is untouched (`recordCtorKey` takes the already-minted id); ctor keys
are drawn from the negative supply and are memo keys only, never stamped into
the graph; flag-off, `recordCtorKey` is never called and `nextRootKey`
numbering is bit-for-bit unchanged.

### §2.2 P2 — declaration-site `c|` injection into the canonical slots

In the inference-unit path for a bodyless ctor member (the
`TOpt.Ctor`/`TOpt.Box` arms feeding `memberOf global canType Nothing`,
LssInfer:540/546): after the unit loads the member's `sigType` through the
SHARED load path, walk the loaded variable's spine to `declaredArity` and
unify each spine slot with `LsMembers ( False, [ cid ] )`, where
`cid = Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g` —
the SAME interned id use sites mint, so declaration and use agree by
construction and the join is idempotent.

- Spine depth: `min declaredArity (spine length)` — for `TOpt.Ctor _ arity _`
  the arity is on the node; `TOpt.Box` is arity 1; `TOpt.Enum` has no arrows
  and is skipped. The LSS_013 arity bound is what licenses stamping every
  spine ordinal, exactly as `standaloneMemberWith (spineDepthForGlobal g)`
  already encodes for the use-site path.
- Payload arrows (e.g. the `Int -> Int` inside `Box`'s parameter) are NOT
  injected — they are not the constructor; their sets come from flow
  (§1 point 3).
- Existing machinery: `Store.unifySlotWithSet`/`unifySlotWithSetC` and
  `Store.arrowParts` for the spine walk; `injectSpineMemberId` (exported from
  LssInfer) is the closest precedent and should be read first — if its
  contract fits (member id + depth + loaded var), CALL it rather than
  re-walking (L-step 7 verifies which).
- Gated on the same flag. With P1 off and P2 on, the injection would land in
  per-copy occurrence slots (annotation copy only) — harmless but pointless;
  the flag covers both so the configuration cannot arise.

**Predicted observable (falsifiable) — CORRECTED BY P0, see §3 P0 RESULT:**
ctor globals' signatures stop being trivial; `sigfacts` gains `<Ctor>|i|m=1,…`
rows for spine ordinals i < arity; `applyFacts` (LssInfer:211) delivers the
member at every `instantiateWithSignature` use. The positions that flip are
those holding a ctor value where the use-site `standaloneArgMember` path
CANNOT fire — containers, records, returns, cross-item transport
(`LssGapCtorInList`'s `runFirst|/a0/l|var` is the witness). The ctors' OWN
head/result arrows do NOT flip: they are storeless-⊤ by construction, a
different mechanism entirely.

### §2.3 What P0 must decide BEFORE P1 is built (AR-7, AR-8)

The arc's gate is ANALYSIS COVERAGE at positions, not provenance. Provenance
(`provBp`) will jump mechanically the moment P1 lands — every keyed ctor arrow
leaves the lost population — **including arrows of never-demanded synthesized
ctors that produce no registry positions at all** (AR-8: `addAliases`/
`addUnion` synthesize unconditionally; unreached ctors inflate the diagnostic
while touching zero positions). Reading `provBp` as success is therefore
FORBIDDEN in this plan; it is reported, not gated.

P0 instruments per-position attribution so §2.2's prediction is checked
against named positions, and defines GO/NO-GO: if the attribution shows the
probes' ⊤/var positions are NOT at ctor ordinals (i.e. the §2.2 story is wrong
about where the uncovered mass sits), STOP and re-scope before building P1.

---

## §3 Phases, lowered

### P0 — position attribution instrument + prediction table

1. **Instrument** (behind `lss.arrowCensus`, joining the existing census
   family in `renderLssReport`): one `ARGF`-style row per uncovered arrow
   position in the registry —
   `pos|<global>|<ordinal-path>|<anno>` where `<anno>` ∈ `top`/`var`, walking
   `g.registry.reverseMapping` with the same traversal `Mono.annoCoverage`
   uses (extend `annoCoverage`'s walker or write a sibling that carries a
   path string; ~40 lines in `Monomorphize.elm`, no new state). Probe-scale
   output is ~15 rows; do NOT run it on the self-compile without `head`.
2. **Run** on `LssGapCtorScale`, `LssGapCustomTypeFn`, `LssGapListOfFns` via
   the existing probe harness
   (`/home/dev/.claude/jobs/94f34a5d/tmp/probe.sh`, or reconstruct: compile
   `test/elm/src/<probe>.elm` standalone with `ECO_MONO_LSS_REPORT=1
   ECO_MONO_LSS_ARROW_CENSUS=1`).
3. **Deliverable:** a table in this plan — each uncovered position, its
   global+ordinal, and YES/NO: does §2.2 predict it flips? GO requires ≥1
   ctor-attributable position per ctor probe. NO-GO → the uncovered mass is
   elsewhere; write the finding and stop.

### P0 RESULT — GO, and it CORRECTS §2.2's predicted observable

Instrument landed (`pos|<global>|<path>|<top|var>` rows behind
`lss.arrowCensus`, a path-carrying sibling of `Mono.annoCoverage` so that
allocation-free walker stays untouched). Measured 2026-08-27:

**`LssGapCtorScale`** (`positions=18 k1=2 var=1 top=15`) — 9 of the 15 ⊤ are at
ctor globals:
`B||top B|/r|top`, `C||top C|/r|top C|/r/r|top`, `D||top … D|/r/r/r|top`.
Arity-1 `A` produces NO position at all; nor does `LssGapCustomTypeFn`'s
arity-1 `Box` (that probe yields ZERO ctor positions).

**These 9 are NOT addressable by injection, and §2.2 was wrong to predict they
would flip.** They are the constructors' OWN registry entries, and a def's own
arrows are stamped ⊤ by the storeless classifier BY CONSTRUCTION — the same
fact `LssPapMembersTest` records ("a def's own result arrow is not the right
place to look"). The probes show it is universal, not ctor-specific: `unA`,
`unB`, `unC`, `unD`, `add`, `mul`, `text`, `useCtor`, `runFirst`, `runAll` —
every def's own head arrow is ⊤ in every probe. Injecting into a slot cannot
change a stamp that never reads the slot.

**Two new probes locate the population that IS addressable.**

`LssGapCtorAsValue` — ctor passed DIRECTLY as an argument
(`useCtor Wrap 7`): `positions=6 k1=3 top=3`, and the uncovered rows are only
`useCtor||top`, `useCtor|/r|top`, `text||top`. **`useCtor|/a0` — the position
holding the constructor — is COVERED.** So ctor members DO reach registry
positions today, via the use-site `standaloneArgMember` path. The plumbing
works; nothing to fix here.

`LssGapCtorInList` — ctor held in a CONTAINER (`makers = [ Wrap ]`):
`positions=7 k1=2 var=1 top=4`, uncovered `makers|/l|top` (producer's list
element) and **`runFirst|/a0/l|var`** (consumer's parameter element). The
use-site path does not fire through a container, so the ctor's identity never
arrives.

**Revised target, and it is narrower than §2.2 claimed:** P2 addresses ctor
positions reached INDIRECTLY — through containers, records, returns, and
cross-item signature transport — where `standaloneArgMember` cannot fire. The
`var` ones (`runFirst|/a0/l`) are the clean case: never written, so a member
delivered by a non-trivial ctor signature fills them. The ⊤ ones
(`makers|/l`) are uncertain and must NOT be promised.

**Corpus population UNMEASURED.** These probes prove the class exists and is
non-empty; they say nothing about how many such positions the self-compile
has. Combined with AR-8 (provenance moves regardless), this means **P3.3's
same-binary coverage A/B is the real test, and a null result there is a
legitimate outcome** to be reported rather than explained away.

**Gate for P3.2 rewritten accordingly:** the decisive probes are
`LssGapCtorInList` (expect `runFirst|/a0/l` var → k1) and `LssGapCtorAsValue`
(expect NO regression — it is already covered). `LssGapCtorScale`'s 9 ctor ⊤s
are expected to be UNCHANGED; if they move, something other than this plan's
mechanism did it and the result needs explaining before it is believed.

### P1 — identity (edit list, in order)

1. `Compiler/Eco/Config.elm` — the 4-site flag pattern (copy `sigRootIdentity`
   verbatim as template): field `ctorIdentity : Bool` + doc citing this plan;
   `defaultLss` entry `False`; decoder `|> D.apply (D.optionalField
   "ctorIdentity" D.bool defaultLss.ctorIdentity)` **APPENDED LAST**
   (positional decoder — the recorded rule); hash token block `lssCT=`
   (differs-from-default pattern).
2. `Builder/Eco/Config.elm` — `applyLssCtorIdentityOverride` + env chain row
   `ECO_MONO_LSS_CTOR_IDENTITY` (copy the `SIG_ROOT_ID` pair).
3. `AssignMVarIds.elm`:
   - `Ctx` + `ctorScope : Maybe String` (init `Nothing` at both `Ctx`
     construction sites); `GlobalMVarState` + `ctorPath : Int`,
     `arrowsCtorKeyed : Int` (both initializers).
   - `assignIds` gains the flag: `assignIds : Bool -> Bool -> Bool -> …`
     (useSolverRoots, censusOn, ctorIdentity). Callers:
     `MonoSolver/Monomorphize.elm:82` (pass `lssConfig.ctorIdentity`),
     `Monomorphize/Monomorphize.elm:96` (pass `False`),
     `tests/…/LssSigRootIdentityTest.elm:204` (pass `False`).
   - `recordCtorKey : String -> ( TypeIds.ArrowId, Ctx ) -> ( TypeIds.ArrowId,
     Ctx )` — clone `recordRootKey`, key `( ctorKey, st.ctorPath )`, and bump
     `arrowsStamped` + `arrowsCtorKeyed` alongside the `arrowRootOf` insert.
   - `TLambda` arm: inside `ctorScope`, increment `ctorPath` FIRST (both
     arms), then in the `_`/`NoArrow` branch route through `recordCtorKey`
     when the flag is on.
   - `withCtorScope` applied at `rewriteNode`'s `Ctor`/`Enum`/`Box` arms.
   - **Annotation side (verified 2026-08-27 — the fold does NOT receive
     `nodes`):** `rewriteAnnotationsByGlobal` (AssignMVarIds:412) gains one
     parameter, `ctorKeys : Dict String ()`, precomputed ONCE in `assignIds`
     (where `nodes` is in scope) as the set of `TOpt.toComparableGlobal g` for
     globals whose node is `Ctor`/`Enum`/`Box`. In the fold, membership of the
     annotation's global sets `ctorScope` — concretely: `rewriteAnnotation`
     builds `ctx0` fresh per annotation (line ~460), so add the
     `ctorScope` field there from the membership check and reset
     `state.ctorPath` to 0 in the same place (per-copy reset falls out of the
     per-annotation `ctx0` construction; no wrapper needed on this path).
4. Census reconciliation: `Engine.Env` + `arrowsCtorKeyed : Int`; wire through
   `initState`; `provenance:` line gains ` ctorKeyed=N`; `stampwalk:` needs no
   change beyond the `arrowsStamped` bump in step 3 (that bump IS the fix —
   assert `RECONCILES=yes` flag-on in P3).
5. **P1 gate (before P2):** save the pre-change binary FIRST
   (`cp -p $BK/bin/eco-compiler $BK/bin/eco-preCtor` — `--target full`
   deletes binaries, recorded trap); frozen-corpus byte-identity
   (`tmp/frozen/` rail), flag-off: new binary's output must byte-match
   `eco-preCtor`'s on the same corpus. This is satisfiable because the
   workload is the FROZEN corpus, not the compiler itself
   (`lss-solver-root-signature-identity.md` §3.2a lesson).

### P2 — injection (edit list)

6. Locate the unit-inference consumption of `UnitMember.sigType`
   (`grep -n "sigType" LssInfer.elm` — the member record is built at
   LssInfer:562; find where units load it during inference).
7. Read `injectSpineMemberId` (exported; the spine-member precedent). If its
   contract is (member id, depth, loaded var, S) → S, call it; otherwise walk
   with `Store.arrowParts` + `unifySlotWithSet` per §2.2. Either way the
   injection runs ONLY for bodyless `Ctor`/`Box` members and ONLY under the
   flag.
8. Member id: `Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal
   g) g` — verbatim the use-site spelling (LssInfer:1397), so interning
   guarantees agreement.

### P3 — battery (every flag-on arm at current defaults, which already carry
### `papMembers`+`sigRootIdentity`)

In order; commands are this arc's standard legs:

1. Flag-off frozen-corpus byte-identity vs `eco-preCtor` (P1 gate re-run
   post-P2).
2. **Probes flag-on** — the decisive cheap leg (~seconds each):
   `LssGapCtorScale`: predict `stampwalk` Δnone +8→0, ΔarrowsNone +20→0
   (union ctors leave the lost population entirely), `sigfacts` rows for
   A|0, B|0..1, C|0..2, D|0..3, coverage `top` 15→≤11 (the four spec head
   arrows flip; payload/other positions per the P0 attribution table).
   `LssGapCustomTypeFn`: Δ +2/+4→0. `LssGapRecordNoFn`/`RecordField`:
   UNCHANGED (+3/+6, +6/+12 — alias ctors are P4; their NOT moving is itself
   a check that P1 touched only what it claims).
   `LssGapEnumNoArrows`, `LssGapNoDecls`: byte-stable on 122/218.
3. Self-compile census A/B (flag-off/flag-on, `ECO_MONO_LSS_REPORT=1`, cold
   `eco-stuff` per leg): `coverage:` is THE gate number — analysis coverage
   must RISE (bar: the flag-off leg's own reading; do not cross-corpus
   against 2872bp, the probe files changed `test/elm` not the corpus, but
   THIS plan's compiler edits move the self-compile corpus — same-binary
   flag A/B avoids the drift entirely, §7.7 lesson). `provenance:`/
   `stampwalk:` recorded (ctorKeyed expected ≈ union-ctor share of 23,729;
   report the split this reveals). `sigfacts` expected to gain one row per
   ctor spine ordinal of every DEMANDED union ctor — likely hundreds; count
   `m=1,c`-class rows separately when reading.
4. Q verifier both arms (`ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_QCENSUS=1`):
   `REPRODUCES=yes diverge=0`. P2 adds a WRITE path (the injection) — unlike
   `sigRootIdentity` this is not memo-key-only, so LSS_037 ("every member
   write is a recorded constraint") applies: check whether the Q recorder
   wraps `unifySlotWithSet` generically (Store:1455 region); if the new call
   site bypasses it, `Q-shadow` will report `unseen` rising — that is a
   defect in the wiring, not noise. Wire the constraint record with the
   injection, not after it.
5. Gate 5b: lower flag-on `out.mlir`, 0 `undefined fast evaluator`, RUN it
   200 s on a real `make` (exit 124 = pass).
6. elm-tests at the pre-existing set (12); E2E `--target full` flag-off AND
   flag-on arms (harness cache is env-blind — touch `test/elm/src` first;
   rebuild `eco-compiler` after, `--target full` deletes it). The 13
   `LssGap*` probes are now IN the suite and must stay green — their CHECK
   lines assert runtime values, so a miscompiling injection fails visibly
   here.
7. Dispatch A/B on the Run-AO rail — RECORDED, NOT GATED (gate 0 policy).
   Ctor members becoming visible to devirt may move `declinedNoInstance` /
   `devirtDirect`; report beside.
8. Flip decision at the end, by gate 0, both flags' worth of evidence in this
   plan's §-ledger first. Not before P4's scope question is at least
   measured (the alias share).

### P4 — alias ctors (deferred, design options recorded, NOT chosen)

The blocker is detection: alias ctors are plain `TOpt.Define`s. Options, to
be decided by measurement of the alias share in P3.3's `stampwalk` residue:
(a) shape detection in `AssignMVarIds` (Define whose body is `Function` over
`Record` of `VarLocal`s matching its args — brittle, zero format impact);
(b) mark at synthesis: `addAlias` registers the name in a new `LocalGraph`
field — **format change to the typed-artifacts cache; carries the
`eco-stuff-target-mismatch` / seed-cache invalidation cost; do not take this
road casually** (AR-1's reasoning applies);
(c) accept the loss if P3 shows the alias share is small.
Note their THREE copies + field-type meta copies need a path scheme that
handles subtree copies (`argNamesWithTypes`/`VarLocal` metas hold parameter
SUBTREES of `funcType`) — the P1 per-copy counter does not transfer as-is;
this is a real design problem, stated rather than hand-waved.

---

## §4 Gates

0. **Analysis coverage must rise flag-on** (self-compile A/B, same binary).
   The probe battery is the mechanism-level version of the same gate and
   fails faster.
1. Flag-off byte-identity vs `eco-preCtor` on the frozen corpus.
2. `stampwalk RECONCILES=yes` in BOTH arms (the AR-4 bump is load-bearing).
3. Q `REPRODUCES=yes diverge=0` both arms; `Q-shadow unseen` must NOT rise
   flag-on (P3.4 — the injection write must be a recorded constraint).
4. Gate 5b lower+RUN.
5. elm-tests pre-existing set; E2E both arms including the 13 `LssGap*`.
6. Unit pins (§5) green.
7. Dispatch recorded.

## §5 Unit pins (write with P1/P2, run in every battery)

1. **Copy-agreement pin** (AssignMVarIds-level, `LssSigRootIdentityTest`
   harness pattern): build `type Box = Box (Int -> Int)` via
   `Pipeline.runToTypedOpt`+`localGraphToGlobalGraph`, run `assignIds False
   False True`, assert: the ctor's node-copy and annotation-copy arrows map
   PAIRWISE to equal negative keys (2 shared keys for Box); flag `False` ⇒
   zero `c|`-keyed entries and `rootKeyEnv`/`nextRootKey` byte-equal to the
   flag-on-absent run.
2. **No gratuitous merging:** `type T = T (Int -> Int) (Int -> Int)` — the two
   structurally identical payload arrows get DISTINCT keys (path-indexed, not
   content-addressed); 4 distinct keys total per copy-pair.
3. **Enum/no-op:** `type Colour = Red | Green | Blue` ⇒ zero entries, zero
   `ctorPath` residue.
4. **Namespace pin (AR-5):** a module whose solver roots occupy
   `rootKeyEnv ( moduleKey, 0.. )` plus a ctor occupying `( "c|…", 0.. )` —
   distinct entries, no cross-contamination.
5. **Injection pin (P2):** pipeline-level, flag-on: `Box`'s signature is
   non-trivial and ordinal 0 names exactly one member; flag-off: trivial.
   Differential, both arms asserted — the arc's rule (a flag test proves
   nothing until the arms differ).
6. **Soundness co-gate:** the `LssPapMembersTest` `joinModule` shape with
   `ctorIdentity = True` added: still no false singleton at the consumer.

## §6 Adversarial review record (run 2026-08-27, against code and paper)

- **AR-1 (design rejection):** stamping in `addCtorNode` — rejected.
  `Can.Type Name` slots ride the typed-artifacts cache
  (`Canonical.arrowSlotToInt` codec; `Compile.elm`'s stamping is deliberately
  unconditional for exactly this reason), so identity there would key the
  on-disk format to an LSS flag. `AssignMVarIds` is post-cache and already
  owns the side-table machinery.
- **AR-2:** alias ctors undetectable at `AssignMVarIds` without either shape
  matching or a cache-format change → P1 scoped to union ctors, P4 holds the
  decision with the measured alias share as input.
- **AR-3 (the big one):** identity alone provably moves nothing — no write
  path targets ctor canonical slots (bodyless member; isolated instantiation
  never writes back). Original one-phase design replaced by P1+P2.
- **AR-4:** without the `arrowsStamped` bump in `recordCtorKey`, the
  `stampwalk` census's `RECONCILES` self-check fails flag-on (its
  `expected` shrinks via `arrowRootOf` while `lostTotal` doesn't).
- **AR-5:** `rootKeyEnv` namespace collision ruled out AND verified at the
  source: module keys are `ModuleName.toComparableCanonical` =
  `author ++ "/" ++ project ++ ":" ++ name` (ModuleName.elm:247) and ctor keys
  wrap `TOpt.toComparableGlobal` = that plus `"." ++ name`
  (TypedOptimized.elm:312) — package names are lowercase-dash-constrained and
  Elm identifiers cannot contain `"|"`, so the `"c|…"` namespace is disjoint.
  Pinned anyway (§5 pin 4).
- **AR-6:** path counter increments on EVERY `TLambda` in scope regardless of
  arm, so copy indices stay structural under any future stamping change.
- **AR-7:** provenance is a diagnostic; gate 0 is coverage; P0's GO/NO-GO
  makes the payoff claim falsifiable before mechanism work starts.
- **AR-8:** unreached synthesized ctors inflate `provBp` with zero coverage
  effect — forbids quoting `provBp` as success anywhere in this plan.
- **AR-9:** injection-completeness argument for the new shared classes
  (§1) — the only producer reaching a canonical class is the ctor's own
  `c|` member; isolated instantiation means use-side producers cannot.
  Plus P3.4's LSS_037 requirement that the new write be Q-recorded.

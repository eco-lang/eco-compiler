# Eco's LSS vs. Brandon et al. (PLDI 2023) — Term-by-Term Mapping and Gap Analysis

**Status: ANALYSIS (2026-08-16).** Maps the shipped LSS implementation onto the paper it
derives from — *Better Defunctionalization through Lambda Set Specialization*, Brandon,
Driscoll, Dai, Berkow, Milano, PLDI 2023 (`lambda-set-specialization.pdf`, this directory)
— and registers every place the implementation falls short of, deliberately diverges from,
or exceeds the paper. Written so that subsequent LSS work is judged against **fidelity to
the paper's analysis**, not against per-consumer patch counts.

The three aims this document measures against (stated 2026-08-16):

1. an LSS analysis **capable of becoming complete** (with enough kernel facts);
2. **not inherently budget-limited** (budgets may remain as practical brakes, but must
   not be load-bearing for termination or soundness);
3. **faithful to the paper**, with divergences justified by the demand-driven mono
   solver, not by accident.

Companion documents — this one does not repeat them:

- `design_docs/monomorphization/lambda-set-specialization-design.md` (v1.1, 1,510 lines)
  — THE design: representation, store, inference, engine, consumers. Its §0 records the
  founding divergence this document analyzes.
- `plans/lss-lambda-set-specialization.md` — the M1–M4 build plan and gates.
- `plans/lss-dispatch-value-extraction.md` — the E-track (census, stamps, devirt) and the
  all-keyed SIGSEGV forensics (its §11.7/E11 arc; older cross-references, including the
  fork plan's, cite it as §11.6).
- `plans/lss-fork-qualified-members.md` — Fix B (LSS_017), spec-qualified lambda members.
- `design_docs/monomorphization/capture-union-representation.md` — the M5 NO-GO on the
  paper's headline lowering representation.
- `design_docs/invariants.csv` lines 606–622 — LSS_001–016 (LSS_017 missing; see §10).

Paper citations use printed page numbers `146:N` (PDF page N+1). All file:line references
verified against HEAD on 2026-08-16.

---

## 1. The paper, compressed

L^src is a **simply-typed** lambda calculus with n-ary products/sums, iso-recursive μ
types, and top-level `def`s (re-evaluated per use; the unit of specialization). LSS runs
three staged, whole-program passes:

1. **Inference** (§4) elaborates L^src into L^annot, where every function type carries a
   lambda set: `τ₁ --σ--> τ₂`. The set grammar is `σ ::= {ℓ₁,…,ℓₙ} | α | μa.σ | a`
   (Fig. 2, 146:6) — concrete sets of *lambda terms*, set **variables** α, and μ-recursive
   sets. **There is no ⊤.** Defs get polymorphic signatures `d⟨ᾱ⟩ : (Q ⇒ τ)` where Q is a
   set of *inclusion constraints* `ℓ ⋸ σ`. Unification only ever equates set variables;
   variables not reaching the signature are **internalized** to minimal concrete solutions
   `S(Q,α) = {ℓ | (ℓ ⋸ α) ∈ Q}`, with μ introduced when α occurs in its own constraints
   (146:11). A provisional-type rule (Σ) forces recursive self-references to the current
   def's own type, so inference **never emits polymorphic recursion** (Thm 4.1, 146:12).
2. **Specialization** (§5) monomorphizes over lambda sets: one fresh `d_spec` per distinct
   `σ̄ ∈ uses(d, π)` (Fig. 9 Mono-Used, 146:13), rewriting `d⟨σ̄⟩` references — **including
   occurrences inside lambda sets** — via μ-aware substitution (Fig. 10, 146:15).
   Termination assumes no polymorphic recursion (Thm 5.1, 146:13). There is no budget.
3. **Lowering** (§5.2, 146:16) converts each function type to a **sum type** over its
   set's members, abstractions to injections, applications to `match`es.

§6 records the implementation obligations: hoist common set subterms via a memoization
cache or representation is exponential (§6.1); delay substitutions or inference is
quadratic (§6.2); **SCCs must be the unit of specialization** over a topologically
ordered def graph (§6.3). The evaluation (§7) reports run time and binary size only —
**no compile-time or specialization-count numbers exist anywhere in the paper** — with
binaries essentially flat under MLton, +1–35% under OCaml (attributed to symbol handling),
and *smaller* under Morphic.

## 2. Eco's implementation, compressed

Eco's source language is **polymorphic** Elm; monomorphization is a demand-driven
worklist (`MonoSolver`), so LSS is interleaved with type specialization rather than
staged. Members are **`Int` ids, not lambda terms** — raw lambda instances carry their
stamped Phase-0 id directly (`srcLambdaKey`, `Engine.elm:212-214`), spec-qualified
lambda instances intern `l|<raw>|<spec>` (`Engine.elm:217-276`), and `g|` globals, `c|`
ctors, `k|` kernels, `a|` accessors intern by string key (`Engine.elm:632-710`). During
solving a set is `LambdaSet1 Bool (Dict Int ())` in the third slot of a `FunL` arrow
(`IO.elm:660`, LSS_007); unification is a total join (`Unify.elm:751-766`); zonk reads
slots back as `LambdaSetAnno = LTop | LSet (List Int)` on `MFunction`
(`Store.elm:1153-1199`, `Monomorphized.elm:854-856`). Inference (`LssInfer.elm`) is
per-SCC, lazy, memoized: a body walk mints members into the def's annotation arrows and
zonks to ground `ArrowFact = {rep, members, top}` signatures. Specialization keys embed
set annotations verbatim when a global routes **keyed** (`toComparableSpecKey`,
`Monomorphized.elm:1979-1985`; `enqueueSpecKeyed`, `Engine.elm:870-917`) — all-globals
keyed is the default since 2026-07-20 — with a per-global budget (64) past which keys
widen, and a `maxSetSize` (8) past which zonked sets widen to `LTop`. Late demand joins
re-translate specs at drain-end flush rounds (LSS_010, `Monomorphize.elm:344-402`).
Consumers: translate-time singleton devirt (E9/E9.1/E9.2, `Translate.elm:2025-2134`),
AbiCloning's singleton fast-dispatch stamps (exact/PAP/staged,
`AbiCloning.elm:1037-1147`), and analysis passes (Borrow, MapTemplate) via
`MonoGraph.lssMemberOrigins`. Everything else lowers through the pre-LSS pipeline.

## 3. Term-by-term mapping

Verdict key: **FAITHFUL** (same mechanism, possibly different clothes) · **PARTIAL**
(the mechanism exists for a fragment) · **DIVERGENT** (deliberate, recorded decision) ·
**ABSENT** (no counterpart) · **N/A** (obviated; no counterpart needed) ·
**EXCEEDS** (stronger than the paper's version). Qualified forms
(e.g. *FAITHFUL under budget*) appear where a single word would mislead.

### 3.1 The type system

| paper | where | Eco | where | verdict |
|---|---|---|---|---|
| set element ℓ = lambda term with capture/param/result types | Fig. 2, 146:6 | interned `Int` member id; five key namespaces (`l|`,`g|`,`c|`,`k|`,`a|`) | `Engine.elm:632-710` | **DIVERGENT** — the founding decision (design §0: "identity-only … not typed lambdas"); §5 below |
| lambda set σ = `{ℓ…}` | Fig. 2 | `LambdaSet1 Bool (Dict Int ())` in-store; `LSet (List Int)` zonked (non-empty, ascending, LSS_001) | `IO.elm:660`, `Monomorphized.elm:854-856` | **FAITHFUL** for the ground fragment |
| **no ⊤ in the grammar** | Fig. 2 | `LTop` / top flag — "statically unknown or deliberately widened" | `Monomorphized.elm:846-856` | **DIVERGENT** — Eco adds the top the paper defines itself against; §6 |
| set variable α | Fig. 2 | `FlexVar` slot Points during solving only; zonked to ground facts, never in signatures or annotations | `Store.elm:146-153`, `LssInfer.elm:564-572` | **PARTIAL** — transient, item-local |
| μa.σ recursive sets | 146:11 | cannot arise: members are atomic ints, sets cannot nest ("μ cannot arise", design §0) | `Occurs.elm:82-84` | **N/A** — obviated by id-only members; the μ-shaped problem re-enters at GAP-3 |
| arrow annotation `τ₁ --σ--> τ₂` | Fig. 2 | `FunL _ _ slot` in-store; `MFunction _ anno _ _` zonked; `Fun1` kept slotless so lss-off is allocation-identical | `IO.elm:636-655`, `Monomorphized.elm:238` | **FAITHFUL** |
| application annotation `(ε₁ as σ)(ε₂)` | Fig. 2 | the callee expression's zonked `MonoType` head annotation, consulted by devirt/AbiCloning (`headAnno`) | `Translate.elm:2034`, `AbiCloning.elm:1037` | **FAITHFUL** |
| abstraction target set `(λ…) as σ` ("the set σ contains at least the lambda currently being constructed") | 146:7 | member injected into the slot by total join; LSS_002 (tested) is exactly the containment: every reachable closure's head annotation is `LTop` or contains its member | `LssInfer.elm:134-150`, `invariants.csv:609` | **FAITHFUL** — with LSS_002 as the tested totality witness |
| element identity across partial application — none needed: L^src has no currying; each staged lambda is its own set element with its own σ | Fig. 1, 146:5 | LSS_013 spine injection: a member id is written on **every result-spine arrow** of the value's type, bounded by declared arity, argument arrows never — "a PAP of member m is m" (design OQ4) | `invariants.csv:619`, `LssInfer.elm:996-1072` | **DIVERGENT** — Eco extends what an element *denotes* (value provenance through partial application) because curried Elm demands it; sound via total join; no paper counterpart |
| inclusion constraints `ℓ ⋸ σ`, constraint set Q | Fig. 2/3 | none accumulated — `unifySlotWithSet` eagerly unions members into slots | `Store.elm:748-801` | **PARTIAL** — eager solving computes the paper's minimal solution `S(Q,α)`, but only because signatures are ground (GAP-2); nothing is deferrable |
| polymorphic def signature `d⟨ᾱ⟩ : (Q ⇒ τ)` | Fig. 2, 146:7 | `LssSignature = {arrows : Array ArrowFact, trivial}`; `ArrowFact = {rep, members, top}` — **ground** | `Engine.elm:80-96` | **ABSENT** as polymorphism; `rep` is the one surviving trace of α — §3.2 |

### 3.2 Inference

| paper | where | Eco | where | verdict |
|---|---|---|---|---|
| F: annotate with fresh set variables per node | Fig. 4, 146:9 | `loadTypeC` mints fresh `FunL` structure + an unconstrained `FlexVar` slot per arrow, per load; ordinals = minting order (LSS_006) | `Store.elm:85-153` | **FAITHFUL** — LSS_006 is F's freshness discipline |
| TIU unification of set variables | Fig. 5, 146:10 | `Unify.elm` FunL×FunL subUnifies slots; LambdaSet1×LambdaSet1 total join with ⊤-absorption and an E9.3 subsumption fast path | `Unify.elm:732-766` | **FAITHFUL** for the ground fragment (never mismatches — as the paper's set-var-only unification never fails) |
| "same α at two positions" in a signature | e.g. `twice⟨α⟩` 146:7 | `ArrowFact.rep`: smallest ordinal whose slot the body unified with this one; `applyFactsGo` replays the linkage by unifying the fresh instantiation's slots | `Engine.elm:80-84`, `LssInfer.elm:208-246` | **PARTIAL** — the *sharing structure* of a polymorphic signature without symbolic elements; the identity-flow case of an inclusion constraint |
| internalization S/I (minimal concrete solutions for non-signature variables) | Fig. 7, 146:11 | degenerate: everything is internalized immediately, because nothing is ever symbolic past zonk | — | **PARTIAL** — correct-by-degeneracy |
| Σ provisional self-type / TIU-Self-Ref | 146:10 | in-flight unit members load annotations through ONE shared scratch memo; self/sibling callees unify against the def's own slots (explicitly labelled "the paper's Σ/TIU-Self-Ref rule") | `LssInfer.elm:18-22, 758-786` | **FAITHFUL** |
| inference unit = SCC, topological order | §6.3, 146:18 | `resolveUnit`: a `TOpt.Cycle` is ONE inference unit, all members, shared Points | `LssInfer.elm:312-375` | **FAITHFUL** (inference side; specialization side diverges — §3.3) |
| Thm 4.1: inference always succeeds, is sound AND **complete** w.r.t. the type system (principality), and emits no polymorphic recursion | 146:12 | set-parameter half of no-poly-rec: enforced by the Σ rule (above). Type-level half: relies on Elm HM being unable to express poly-rec (recorded decision, `monomorphization-plan.md:1612-1616`), with **no watchdog**. No completeness claim exists or is measurable for Eco's inference — the census's unconstrained-LTop mass is the distance from it | `LssInfer.elm:81-82` | **PARTIAL** — see GAP-8; the completeness clause is aim 1's formal benchmark |
| let-bound function flow (the paper has no let-generalization; §6.3 turns SCC members into let-bound lambdas *within one def*) | 146:18 | `joinArrowSets` §7.4 policy: all uses of a let-bound function share ONE set (union over uses); structural divergence or a generalized position calls `poisonBoth` — which bumps **no census counter**. Local-multi function args bypass member injection entirely; E4a USE-transport partially closes it | `LssInfer.elm:1075-1218`, `Translate.elm:2931-2936` | **PARTIAL** — see GAP-9; Elm's polymorphic `let` has no L^src counterpart, so this axis is Eco's own to get right |

### 3.3 Specialization

| paper | where | Eco | where | verdict |
|---|---|---|---|---|
| specialize over σ̄: one fresh `d_spec` per `σ̄ ∈ uses(d,π)` (Mono-Used) | Fig. 9, 146:13 | keyed routing: the spec key IS the fully-annotated demand type (member ids embedded verbatim), one spec per distinct key | `Engine.elm:870-917`, `Monomorphized.elm:1979-1985` | **FAITHFUL under budget** — and unified with *type* monomorphization in one key, which the simply-typed paper never needed |
| Mono-Unused: drop defs with `uses = ∅` | Fig. 9 | demand-driven laziness: an undemanded spec is never enqueued, never exists | `Monomorphize.elm` worklist | **EXCEEDS** — free, and finer-grained |
| μ-aware substitution ψ: rewrite `d⟨σ̄⟩ → d_spec⟨⟩` **inside lambda sets** | Fig. 10, 146:15 | for lambdas: Fix B qualification `l|<raw>|<specId>` at mint time — the id-space image of substituting the specialized instance into sets. For standalone `g|`/`c|` members: **nothing** — sets keep the family name | `Engine.elm:238-276` vs `LssInfer.elm:649-673` | **PARTIAL** — faithful for `l|`, ABSENT for `g|`/`c|`; this is GAP-1 |
| no budget; termination from no-poly-rec | Thm 5.1 | `maxSpecsPerGlobal = 64`; past it, keys widen to `LTop` (`widenedByBudget`). The budget is also the **only terminator** of the specs→qualified-members→keys spiral | `Engine.elm:876-894`, fork plan §6.5 | **DIVERGENT** — GAP-3; budget is currently load-bearing, violating aim 2 |
| specialization unit = SCC | §6.3 | per-MEMBER: `specializeCycle` translates only the demanded member; siblings enqueue as separate specs; joined demands propagate around the cycle via LSS_010 flush rounds | `Translate.elm:769-797` | **DIVERGENT** — sound via monotone joins; iterative rather than simultaneous — GAP-7 |
| staged: inference completes, then specialization | §4→§5 | interleaved; late demand joins re-translate via dirtySpecs + drain-end flush (≤100 rounds, then loud EngineBug) | `Monomorphize.elm:344-411` | **DIVERGENT-EQUIVALENT** — §4 below |
| def duplication semantics (defs re-evaluate per use; ML value restriction discussed) | 146:5 | Elm is pure; duplication is trivially safe | — | **N/A** — simpler than the paper |

### 3.4 Lowering and consumers

| paper | where | Eco | where | verdict |
|---|---|---|---|---|
| function type → sum over members; application → `match` | §5.2, 146:16 | **no sum lowering exists.** Singleton sets: direct dispatch (three stamp arms: exact LSS_009, PAP LSS_011, staged LSS_014; ctor/fn-global/kernel devirt LSS_015/E9.1/LSS_016). Everything else: the generic `papExtend` pipeline. Multi-member sets: census-only in the *dispatch* path (AbiCloning), but since G-1 (2026-08-15) **analysis consumers do act on them** — MapTemplate licenses a clean multi-member callback generically (`MapTemplate.elm:492-597`, default-off flag) and Borrow meets multi-member `BorrowSig`s per call site (BORROW_006) | `AbiCloning.elm:1037-1208`, `Translate.elm:2025-2134` | **DIVERGENT** — deliberately, on census evidence (M5 NO-GO); but the evidence is partly downstream of GAP-2 — see GAP-6 |
| the lowered sum's per-variant environment (capture record) | §5.2 | recovered per-instance by AbiCloning (`captureAbi` from the indexed `MonoClosure`), since id-only members carry no types | `AbiCloning.elm:395-413` | **DIVERGENT** — the cost of id-only members: ABI must be re-derived from instances |
| entry point: `τ has no function types` (AT-Entry) | Fig. 3, 146:7 | kernel/port/debug ABI arrows are top-poisoned (LSS_004) | `Store.elm:804-848` | **FAITHFUL in spirit** — same boundary; the paper forbids, Eco widens |
| Thms 5.6/5.7: end-to-end semantics preservation (146:17; Isabelle/HOL mechanization covers *inference*/Thm 4.1 only — the §5 theorems are paper proofs). The paper's L^annot semantics are BY DEFINITION its erasure's semantics (146:6) | 146:17 | the same erasure correspondence, exactly: annotations are inert metadata; the lss-off / all-LTop pipeline IS the erasure, and LSS_005 (widening changes performance, never semantics) + LSS_002/LSS_010 tests + the lss-off byte-identity gate are what enforce it | `invariants.csv:612, 609, 617` | **DIVERGENT** assurance class: the paper proves, Eco tests + degrades gracefully — but the *object* being assured (erasure-equivalence) is the same on both sides |

### 3.5 Implementation considerations (§6)

| paper | where | Eco | where | verdict |
|---|---|---|---|---|
| §6.1 common-subterm sharing via memoization cache (else exponential) | 146:17-18 | members ARE atomic ints — maximal sharing by construction (design §7.6: "the structure-sharing warnings … don't bite id-only sets") | design doc §7.6 | **EXCEEDS** — but the discarded payload is exactly what GAP-1 is missing |
| §6.2 delayed substitution (else quadratic) | 146:18 | no substitution exists to delay; Fix B qualification is O(1) interning at mint | `Engine.elm:269` | **N/A** |
| §6.3 SCC unit, topological order | 146:18 | inference: yes; specialization: no (per-member) | §3.2/§3.3 | split verdict |

### 3.6 Things Eco has that the paper does not

No paper counterpart exists for any of these; they are all Eco-specific obligations,
and none is a fidelity violation:

- **Kernels/FFI** — LSS_004 poison at every kernel/port/debug boundary; `k|` members
  head-only (`kernelToSig` misaligns at inner arrows); devirt whitelist (`List.cons`/2
  only). The paper's world has no opaque code. This is where aim 1's "enough kernel
  facts" lives — GAP-4.
- **`LTop` and the LSS_005 graceful-degradation lattice** — every knob falls back to the
  pre-LSS pipeline; `enabled=False` is byte-identical. The paper has no off-switch.
- **The observability layer** — the LssStats census (`widened{bySize,byKernel,byBudget}`,
  `devirtDirect/Kernel`, `sizeHist`, `unqualifiedLambdaMints`, `Engine.elm:101-122`;
  `topSiteShapes` lives in AbiCloning's stats, `AbiCloning.elm:132`, rendered under the
  same census banner), `ECO_MONO_LSS*` env surface, artifact-hash tokens.
- **Staging/wrapper identity discipline** (LSS_008) and representative interchangeability
  (LSS_009) — obligations created by having a GlobalOpt pipeline between mono and
  emission; the paper lowers directly.
- **The accessor namespace `a|`** — `.field` values; no paper analogue.

## 4. Staging: three passes vs. demand-driven interleaving

The deepest *legitimate* divergence. The paper runs inference to completion over a
topologically ordered whole program, then specializes, then lowers. Eco cannot: the
monomorphizer is demand-driven, and LSS piggybacks on its worklist.

What the interleaving **buys**: Mono-Unused for free (undemanded code never materializes);
no whole-program L^annot ever exists in memory; `enabled=False` reproduces the pre-LSS
pipeline byte-for-byte.

What it **costs**, and how each cost is discharged:

1. **Demands arrive incrementally**, so a spec translated against an early demand may be
   invalidated by a later join. The paper never faces this (all σ̄ known before
   specialization). Eco's replacement is the LSS_010 machinery: the registry's stored
   type is the annotation JOIN of every admitted demand; a join that changes an
   already-scheduled spec marks it dirty; drain-end flush rounds re-translate
   (`Monomorphize.elm:344-411`). Termination: joins are monotone in a finite lattice;
   `maxJoinRounds = 100` turns livelock into a loud EngineBug. Translate-time singleton
   devirt is explicitly "provisional-singleton soundness rides LSS_010"
   (`Translate.elm:2021-2023`). This is a faithful re-derivation of the paper's staging
   guarantee as a fixpoint — equivalent **for soundness**; whether the paper's
   *precision* survives interleaving unchanged is exactly what §9 declines to claim.
   One carve-out belongs in the record: only body-bearing nodes are re-translation
   eligible (`nodeSupportsRetranslation`, `Monomorphize.elm:790-820`) — ctor/enum/box/
   kernel/manager specs are shape-derived and never re-translated, harmless by
   construction since their registry types are still joined.
2. **A pre-spec phase exists** (signature inference runs before any spec of the unit is
   translated), so anything minted there cannot know instantiations. This is the origin
   of the standalone-member phase asymmetry (GAP-1) and of "signature-transported raw
   lambda members decline at AbiCloning — unstampable-but-sound" (`Engine.elm:233-236`).
   The paper's staging has the *same* property (inference precedes specialization) but
   its sets stay **symbolic** through that phase and are substituted during
   specialization; Eco's are ground from the start, so what the paper defers, Eco loses.

## 5. Element identity — the central fidelity axis

What is an ℓ? In the paper: a lambda term **with its types**, and — after μ-aware
substitution — with its *instantiation*: post-specialization, every set element is a
lambda term whose types, and whose `def` references (`d⟨σ̄⟩ → d_spec⟨⟩`, occurring
*inside* the element — a bare def reference is never itself an element, per the Fig. 2
grammar), have been substituted concrete. Element identity = **syntactic origin ×
instantiation**. Notably, the paper itself already trims element identity where it can:
lambdas inside *inclusion constraints* are a separate syntactic category that does NOT
track capture expressions (146:8) — a partial precedent, from the paper's own hand, for
Eco's harder cut to identity-only members.

Eco's five namespaces, measured against that:

| namespace | identity carried | paper-faithful? |
|---|---|---|
| `l|` lambda instances (post-Fix-B) | source lambda × **minting SpecId** (`l|<raw>|<spec>`, keyed-routed) | **YES** — Fix B is the id-space image of μ-aware substitution. Proven necessary by the §11.6 SIGSEGV: raw ids under keying = one id over divergent instances = the representative hijack |
| `g|` globals | source global only — one id over **many** SpecIds | **NO** — a family name; the paper's output cannot contain one |
| `c|` ctors | source ctor only | **NO** — same, mitigated by ctor interchangeability (LSS_015: "stronger than LSS_009") |
| `k|` kernels | kernel name, head-only | N/A (no paper analogue); completeness-relevant (GAP-4) |
| `a|` accessors | field name | N/A; `.field` is layout-generic — arguably *correctly* a family |

Two identity rules ride alongside the namespaces. The **kernel-alias fold**: a global
whose body is exactly a kernel reference (`cons = Elm.Kernel.List.cons`) mints the `k|`
member, never a `g|` twin — "a split g|/k| identity would join to a 2-set and kill every
singleton consumer" (`LssInfer.elm:950-968`, `Translate.elm:3096`) — one value, one
element, exactly the discipline the paper gets for free from syntactic identity. And
**spine provenance** (LSS_013, §3.1): a member id inhabits every result-spine arrow of
its value's type, so a partial application of m *is* m — an extension of element
denotation the curryless paper never needed.

The asymmetry is not an oversight but a consequence of **where each mint runs**: `l|`
qualification reads ambient context (`itemAux.currentSpecId`) available at mint time;
a standalone reference's instantiation is a *result* of translation
(`translateVarRef → enqueueSpec`, `Translate.elm:1499-1513`), which postdates the
transport mint (`argUnifyVar` injects before param unification,
`Translate.elm:3035-3053`). Resolving early from the in-flight demand would be
**unsound** — a qualifier naming spec S₁ when the runtime value is S₂ licenses proofs
about the wrong code, the hijack through another door (and the under-resolved-demand
failure class is real: the CNumber/Float demand-timing bugs). A SpecId-qualified re-mint
of standalone members was examined and rejected on exactly this circularity, 2026-08-16
(session decision; no plan file — this paragraph is its record).

**The faithful repair direction** is the paper's own: keep the element symbolic until the
instantiation exists, then ground it. In store terms: standalone slot entries stay
symbolic `(Global, slot)` during solving and ground to `g|G|<typeKey>` at **zonk**, where
the arrow's demanded type is sitting in the very slot being read — the qualifier is the
*type* (= the instantiation, = what picks the SpecId), not the SpecId itself, so the
mint-before-resolve circularity dissolves, and both the inference-phase and
translation-phase mints ground identically (no dual-id split). This is a scoped store
redesign (slot representation + zonk + `sources`), not a new analysis.

## 6. ⊤ and widening — what LTop actually measures

The paper's headline: "no expressiveness limitations, and never falls back to
traditional dynamic function representations" (146:2); its related-work section frames
prior work's failure modes as poisoning toward exactly such a fallback. Eco has the
fallback (`LTop` lowers to the entire pre-LSS pipeline) and its census names the causes.
Two censuses matter, and they say different things:

**E0.5, unkeyed, 2026-07-16** (`lss-dispatch-value-extraction.md:268-297`), 388,035
zonked arrows: 89.3% LTop, of which widening accounts for almost nothing
(`byKernel=3,004 bySize=35 byBudget=0`) — **the LTop mass is UNCONSTRAINED slots, not
widened ones**, and all 8,673 def signatures are trivial. Recorded verdict: "coverage is
ANALYSIS-limited, not mechanism-limited." The analysis simply propagates almost no
cross-def set flow through signatures.

**All-keyed (current default), 2026-08-14** (`list-map-mlir-template.md:2000-2001`):
`widened: bySize=462 byKernel=4102 byBudget=50778`; `topSiteShapes global=14143
local=7361 kernel=3785`. Under keying, cross-def flow rides the **demand channel**
(annotation-sensitive spec keys) instead of signatures — and the budget becomes the
dominant *widening* source by 12×.

So Eco has two distinct distances from the paper's no-⊤ ideal, and they are commonly
conflated:

- **Unconstrained-LTop** — a *flow* problem, not a widening problem, and itself
  composite (per the E0.5 verdict, `lss-dispatch-value-extraction.md:286-296`):
  (i) the empty signature channel (GAP-2); (ii) the let-boundary and local-multi
  transport gaps (GAP-9) — `topSiteShapes local=7,361` is this component's footprint,
  ⊤-through-locals being the dominant residual callee shape; (iii) an
  **escape-by-soundness** class — IO bind continuations that escape into the returned
  value, where the E0.5 verdict is explicit that "no analysis precision helps" and only
  defunctionalization-style transformation (the shelved E8) would; this component is a
  *soundness floor*, not a gap. No budget change touches any of the three.
- **Widened-LTop** — budget (GAP-3), kernels (GAP-4), size cap (GAP-5), in that order
  of measured magnitude under the shipping config.

LSS_005 (widening monotonicity: any stricter policy changes annotations, spec counts and
dispatch tiers, "never observable behavior") is Eco's own construction with no paper
counterpart — the paper has nothing to widen to. It is what makes every gap below a
performance gap rather than a correctness risk, and it is the property that must be
preserved by any repair.

## 7. Gap register

Each gap: what the paper does / what Eco does / why / consequence for the aims / repair
direction / cost class.

### GAP-1 — Standalone set elements are family names (fidelity: HIGH)

**Paper:** post-specialization, sets name specialized entities (μ-aware substitution,
Fig. 10). **Eco:** `g|`/`c|` members name source globals; one id ↔ many SpecIds; `l|` is
already faithful (Fix B). **Why:** the id-only-members decision plus the phase asymmetry
(§5). **Consequence:** every consumer needing code rather than a name must re-derive it
with type context or decline — `devirtGlobalTarget`'s annotation-arity re-derivation,
MapTemplate's G-3 layout matching, `unresolved{global=15}`, Borrow's
`standalone members resolve PUnresolved pending v2` (BORROW_006). **Repair:**
symbolic-until-zonk grounding by demanded type key (§5). **Cost:** scoped store redesign;
artifact-affecting under keyed routing (member ids change → keys change), so it needs the
full gate battery and a bootstrap fixed point. **Aims served:** 3 directly; 1 indirectly
(consumers stop needing per-consumer resolution machinery).

### GAP-2 — No lambda-set polymorphism in signatures (completeness: HIGH)

**Paper:** `d⟨ᾱ⟩ : (Q ⇒ τ)`; the signature channel carries symbolic set flow between
defs; internalization keeps only signature-reaching variables polymorphic. **Eco:**
`ArrowFact` is ground `{rep, members, top}`; only `rep` survives of α (the
identity-linkage case). Measured: **8,673/8,673 signatures trivial** — the callee→caller
channel is empty in practice; all cross-def flow is demand-side (keyed keys) or
absent. **Why:** v1 scope (design §7.1 frames facts as "the paper's Q ⇒ τ for
AT-Def-Ref", but only the ground fragment was built). **Consequence:** the largest single
component of the unconstrained-LTop mass (§6) — though not all of it; GAP-9 and the
escape-by-soundness class own the rest. No amount of budget or kernel facts recovers
flow the analysis never propagates. **Repair direction:** generalize `ArrowFact.rep`
from "same slot" to "flows-into" — `members : List (Ground Int | FromArrow ordinal)` —
i.e., re-admit the inclusion-constraint form for the *parameter-to-inner-position* case
(a def that passes its function parameter into `List.map` records `FromArrow j` on the
inner arrow rather than nothing). That is precisely the paper's α-in-signature,
restricted to ordinals, with internalization at application. One rider: the signature
readback path (`zonkSigGo`, `LssInfer.elm:525-572`) applies **no size cap** today —
dormant while signatures are trivial, it goes live the moment this repair lands, so the
widening policy must be extended to the signature channel in the same change. **Cost:**
inference-layer redesign; the largest item here, and the prerequisite for GAP-6's
evidence to mean anything. **Aims served:** 1 and 3.

### GAP-3 — The budget is load-bearing (aims 2+3: HIGH)

**Paper:** no budget; forks per σ̄; termination purely from no-poly-rec; empirically
binary growth stays modest (Fig. 11: flat under MLton, smaller under Morphic, up to
+35% under OCaml, attributed to symbol handling) — though the paper measures **no
compile-time cost at all**, so fork-don't-widen's compile-time viability at Eco's scale
is genuinely unknown territory. **Eco:** `maxSpecsPerGlobal=64`; past it keys widen (`widenedByBudget=50,778`
shipping; 46,394 at Run M). Two roles are currently fused: (a) fan-out control — the
legitimate "practical brake" of aim 2; (b) **the only terminator of the
specs→qualified-members→keys spiral** (fork plan §6.5; verified 2026-08-16: no other
guard exists — `maxJoinRounds` is a crash backstop, not a terminator). **Repair:**
separate the roles. For (b), a μ-analogue over the member universe: qualification is the
id-space image of substitution, and the spiral `Q(L,S₁) → S₂ → Q(L,S₂) → …` is exactly
the case where the paper's `S` function emits `μa.{ℓ[α↦a]}` — detect the self-similar
family (the qualified ids of one raw lambda along one demand chain) and tie it to a
canonical recursive-family id instead of minting fresh. With (b) discharged, raising or
removing the budget becomes a measured *policy* choice (the F-2A sweep — N=64→1024 costs
+4.36% binary, ~+6% mono wall, licensed 58→143 — is the only fork-cost data in
existence, paper included). Additionally requires GAP-8's watchdogs as the safety net the
paper gets from Thm 4.1. **Cost:** medium (family detection in `lambdaInstanceMemberId`
+ census); the watchdogs are small and already designed. **Aims served:** 2 directly, 3.

### GAP-4 — Kernel arrows are opaque (completeness: MEDIUM, the "enough kernel facts" axis)

**Paper:** no FFI exists. **Eco:** LSS_004 poisons every kernel/port/debug-crossing
arrow (`byKernel=4,102`); `k|` members are head-only because `kernelToSig` misaligns at
inner arrows; kernel devirt whitelist is one entry. Note the poison is *calibrated*:
`List.map/foldl/foldr/filter` are plain Elm and unpoisoned; the gap is `map2-5`,
`sortBy/sortWith`, `Task`/`Process` internals. **Repair:** a per-kernel per-parameter
fact axis — the LSS analogue of the already-planned `hofParams`
(`plans/effect-polymorphic-purity.md`: PInvokes/PStoresOnly/POpaque per param, audited
from C++ bodies, 11 rows planned, unimplemented). For LSS the needed axis is set-flow:
which params the kernel applies, stores, or tunnels to its result — enough to thread a
member *through* `List.map2` instead of poisoning it. Fixing the `kernelToSig` inner-arrow
alignment is a prerequisite for `k|` spine injection. The paper's related-work section
supplies the theoretical frame for exactly this shape of fact: it reads the constraint
context Q as an effect judgment (146:21-22) — a per-kernel per-param axis is the manual
transcription of the Q a kernel body would have induced had it been in-language.
**Cost:** audit-driven, incremental per kernel; exactly the shape of work aim 1
anticipates. **Aims served:** 1.

### GAP-5 — `maxSetSize = 8` (completeness: LOW)

**Paper:** arbitrarily large finite sets are kept (a many-variant sum). **Eco:** zonked
sets over 8 widen (`bySize=462`; enforced only at annotation readback, `Store.elm:1184`).
**Consequence today:** near zero in the shipping config — the *dispatch* path acts on
singletons only, so a 9-member set and `LTop` behave identically there. Not categorically
zero any more: since G-1 (2026-08-15) MapTemplate licenses clean multi-member sets
(default-off flag), and Borrow's per-site sig meet consumes them (census-only), so for
those consumers a widened set and a kept set genuinely diverge. **Repair:** raise/remove
when a default-on multi-member consumer exists (GAP-6); then re-census. JSON-only knob;
no env var. **Aims served:** 1, cheaply, later.

### GAP-6 — No sum-type lowering; multi-member sets have no consumer (fidelity: MEDIUM, gated)

**Paper:** §5.2 lowering is the headline — every application becomes a `match` over the
set. **Eco:** singleton-direct or generic in the dispatch path; multi-member sets are
census-only in AbiCloning (`AbiCloning.elm:1172-1197`) though analysis consumers now
exist (G-1's MapTemplate arm, default-off; Borrow's sig meet — §3.4); the paper's
representation was explicitly evaluated and **rejected on census**: M5 capture-union
NO-GO (k≥2 share ~0% of hot dynamic creates), E3 small-set dispatch CLOSED (2 static
sites, 0 dynamic events), `multiSetSites 2→1 3→1 5→1`. **The honesty caveat:** all of that evidence is *downstream of GAP-2* —
with trivial signatures and no cross-def flow, multi-member sets largely *cannot form*
(the G-1 fixture attempts all widened to LTop through three separate mechanisms). The
NO-GO is sound for the current analysis; it is not evidence about the paper's claim.
**Repair ordering therefore matters:** GAP-2 first, re-census, and only then revisit M5 /
`multiset-defunctionalization-design.md` (its §7 already defines the deciding census).
**Aims served:** 3, conditionally.

### GAP-7 — Specialization unit is the member, not the SCC (fidelity: LOW)

**Paper:** §6.3 requires SCCs as the specialization unit. **Eco:** inference is
SCC-granular (faithful); specialization is per-member with LSS_010 flush rounds carrying
joined demands around the cycle iteratively. Sound (monotone); the recorded costs are
precision seams: `VarCycle` members mint head-only (`LssInfer.elm:675-681`), and
`injectArgLambdaMember` has no `VarCycle` arm at all (`Translate.elm:3110-3111` wildcard)
— a cycle member passed as a function argument transports **no** member. **Repair:**
close the two seams (small); unifying the spec unit itself is not warranted — the flush
mechanism is the demand-driven equivalent. **Aims served:** 3 marginally, 1 slightly.

### GAP-8 — No poly-rec/blowup guard behind Thm 4.1's assumption (aims 2: MEDIUM)

**Paper:** inference *provably* never emits polymorphic recursion; specialization
termination is a theorem. **Eco:** the set-parameter half is enforced (Σ rule, §3.2); the
type-level half rests on "Elm HM cannot express it" with **zero** enforcement — the drain
has no fuel, spec-count, or type-size cap (verified 2026-08-16); the subst engine has no
limits at all; a front-end regression admitting poly-rec means a silent hang/OOM. The
designed watchdogs (`ECO_SPEC_TYPE_NODE_LIMIT` 400k, `ECO_SPEC_BREADTH_LIMIT` 50k, Aug 4
2026) were never implemented, and their plan file (`plans/mono-perf-and-watchdogs.md`)
does not exist in this checkout — the design survives only in session memory.
**Repair:** implement the two watchdogs with clean use-site-annotating errors. They are
the precondition for GAP-3's budget demotion: the paper terminates on a theorem; Eco,
lacking the theorem for its type dimension, needs the loud backstop before un-capping
anything. **Cost:** small. **Aims served:** 2.

### GAP-9 — Let-boundary and local-multi flow, with counterless poison (completeness: MEDIUM)

**Paper:** no counterpart problem — L^src has no let-generalization (§6.3 even *relies*
on let-bound lambdas inside a def being unproblematic). Elm's polymorphic `let` creates
the axis. **Eco:** two recorded v1 policies. (a) `joinArrowSets` (design §7.4,
`LssInfer.elm:1075-1218`): all uses of a let-bound function share one set — union over
uses, sound — and any structural divergence or generalized position calls `poisonBoth`,
which **bumps no census counter** (verified: `LssInfer.elm:1211-1218` calls
`poisonArrowSets` with no stats bump). That is a direct violation of this document's own
aim-1 criterion — an LTop source with no counter. (b) Local-multi function arguments
bypass member injection entirely (`Translate.elm:2931-2936`, "no member, no stamp");
E4a's USE-transport (`Translate.elm:4747, 4782`) partially closes it. **Consequence:**
component (ii) of the unconstrained-LTop mass (§6); `topSiteShapes local=7,361` is its
measured footprint — the dominant residual callee shape. **Repair:** first
instrument (`widenedByLet` counter on `poisonBoth`; a local-multi decline counter), then
per-use set separation (the design's own "vNext upgrade") sized by the new counters.
**Cost:** instrumentation trivial; per-use separation medium. **Aims served:** 1
directly; 3 (the paper's no-⊤ ideal demands every ⊤ be accounted for).

### Non-gaps (checked; do not re-open without new evidence)

- **μ-recursive sets** — obviated by id-only members (design §0); the residual μ-shaped
  problem is GAP-3's spiral, handled there.
- **§6.1 sharing / §6.2 delayed substitution** — obviated (EXCEEDS / N/A, §3.5).
- **Capture-ABI recovery** (§3.4's per-variant-environment row) — the accepted price of
  id-only members: what the paper's elements carry syntactically, AbiCloning re-derives
  from indexed instances (`AbiCloning.elm:395-413`). Sound (LSS_008/009 discipline);
  repairing it *is* GAP-1/GAP-2's element enrichment, not separate work.
- **Def-duplication semantics** — obviated by purity.
- **Entry-point boundary** — LSS_004 covers it (widen where the paper forbids).
- **Eager constraint solving** — degenerate-correct today; becomes real work only inside
  GAP-2's repair, where it belongs.
- **`Fun1`/`FunL` dual arrows, `LTop`-lowering pipeline, LSS_005 lattice, census,
  staging/wrapper identity discipline** — Eco-specific obligations, all sound, none owed
  to the paper.

## 8. Scorecard against the three aims

**Aim 1 — capable of completeness.** The binding constraints, in order:
GAP-2 (the signature channel is empty — the analysis cannot currently *see* most flow),
GAP-9 (the let/local flow axis, whose poison is today counterless), then GAP-4 (kernel
facts — the axis the aim itself names), then GAP-5 (trivial), with GAP-7's two seams as
small change and GAP-1 contributing indirectly (resolvable elements retire per-consumer
resolution machinery). "Complete" here has a precise meaning the census can track: every
arrow either carries the true inhabitant set or is `LTop` for a *reason with a counter*
— the unconstrained-LTop mass goes to zero, with the §6 escape-by-soundness class as the
recognized floor.

**Aim 2 — budget as policy, not crutch.** GAP-3 (split the budget's two roles; μ-tie the
qualification spiral) gated on GAP-8 (watchdogs first — they are the substitute for the
termination theorem Eco does not have). After both, `maxSpecsPerGlobal` can be raised or
lifted experimentally with the F-2A sweep as the cost baseline; keep `LSS_005` as the
invariant that any such experiment is behavior-neutral.

**Aim 3 — faithfulness.** Already faithful: the store/unification layer, F/LSS_006,
Σ/TIU-Self-Ref, Mono-Used-under-keying, Fix B for `l|`, LSS_010-as-staging. The ordered
distance: GAP-1 (element identity for standalones), GAP-2 (signature polymorphism),
GAP-3 (the paper does not widen; demoting the budget is a fidelity move as well as a
policy one), GAP-6 (revisit lowering only after GAP-2 re-census), GAP-7/GAP-9 (seams
and accounting).

**Suggested order overall:** GAP-8 → GAP-3 (small, unblocks experimentation safely) →
GAP-9's instrumentation (trivial, sharpens every later census) → GAP-1 (scoped, high
fidelity yield) → GAP-2 (the big one) → re-census → GAP-4 incrementally → GAP-6
decision → GAP-5/7 and GAP-9's per-use separation as ride-alongs.

## 9. What the paper cannot tell us

For honesty about the limits of "faithful": the paper's L^src is simply typed; **nothing
in it addresses a polymorphic source language**, and its evaluation translates Morphic
*out* to SML/OCaml after LSS has already produced first-order programs. Eco's central
complication — that a set element's identity must compose with *type* instantiation
(GAP-1), and that type and set specialization share one registry — has no paper
counterpart; Fix B and the proposed type-key grounding are original work the paper only
motivates by analogy (its μ-aware substitution). Likewise the paper measures **no
compile-time costs**, so Eco's budget-vs-fork trade has no literature baseline beyond
Eco's own F-2A sweep; and the paper's no-⊤ claim is about *expressiveness*, licensed by
whole-program staging — the demand-driven equivalent (LSS_010) reproduces its soundness,
but nothing in the paper says the *precision* survives interleaving unchanged. Where this
document says FAITHFUL, it means: the mechanism is the paper's; where it says DIVERGENT,
the burden of justification is on Eco, and the recorded censuses carry it.

## 10. Bookkeeping surfaced by this analysis

- **LSS_017 was not in `invariants.csv`** despite being enforced code discipline
  (`Engine.elm:217-276`), specified in the fork plan (§10), and *referenced by*
  BORROW_006 — **row added 2026-08-17** (closing the fork plan's B4 debt). Still open:
  LSS_009's row does not carry its LSS_017-discharge amendment, and LSS_012 (a
  permanently skipped id, reserved for the closed E3) is unannotated.
- **Stale line references**: fork plan §6.5 cites `Engine.elm:712-723` for budget
  widening — now `Engine.elm:876-894`.
- **`lss-foundation-report.md`** is cited by the design doc (lines 17, 65, 1503) and the
  founding plan (line 82) but exists nowhere in the tree.
- **`plans/mono-perf-and-watchdogs.md`** (and `plans/alm-derived-optimizations.md`) do
  not exist in this checkout though the Aug 4 memory records them; the watchdog design
  (GAP-8) survives only in memory and should be re-materialized as a plan when picked up.
- **THEORY.md and `design_docs/theory/` contain zero LSS content** — if that corpus is
  meant to cover every major analysis, LSS is the largest uncovered one; this document
  and the design doc are the de-facto theory references.
- The `≤8 members` comment at `Unify.elm:757-758` describes steady state, not an
  enforced bound — the cap lives only at zonk readback (`Store.elm:1184`); in-store sets
  can transiently exceed it. Harmless today; worth a comment fix.

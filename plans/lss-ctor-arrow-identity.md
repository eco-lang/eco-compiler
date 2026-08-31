# Ctor payload-arrow transport — v2, rebuilt from the provenance census

**Status: CLOSED 2026-08-31 — superseded by `plans/lss-var-chain-roots.md`.**
Shipped from this plan: `lss.destrAnno` (Fix A + settleCtorRows Fix B,
default-on, §9.7–9.9); the ⊤ caller-attribution machinery (§9.3); the §12
var chain-root attribution and its census instruments (spec-idx pos rows +
k1 member naming) — which became the successor plan's evidence base. Parked
exploitation recorded here: raise-with-identity-forwarding (§11.1) and sum
lowering (§11). The §12.2 mechanism sketch (M-A/M-B/M-C/M-D) is superseded
by the successor plan's reviewed phases — read THAT plan, not §12.2, for
the attack order.

**Original status:** REBUILT 2026-08-30 from the bare concept, superseding the 2026-08-27
plan (its still-binding findings are carried over in §6; its P1 "identity side
table" and P2 "declaration-site c| injection" are DEMOTED to one candidate
component (§3 P2.c) — the census shows the mass is elsewhere). Adversarial
review §7; implementation-ready lowering §8.

**Flags:** `lss.ctorSpine` (`ECO_MONO_LSS_CTOR_SPINE`, token `lssCS=`),
DEFAULT-OFF, for the P1 root completions; P2 reuses the existing
`lss.argPoints` (`lssAP=`) machinery, flipped only by its own measured gates.

---

## §0 Bare concept

**A constructor is a known function. When it — or any function value — is
stored inside a data structure, its lambda set must survive the whole trip:
INTO the container at the construction site, ACROSS item boundaries, and OUT
at the destructure/application site.**

In the paper (Brandon et al., PLDI 2023) this costs nothing: every arrow
type position — including arrows inside a datatype's type arguments — carries
a lambda-set variable; unification (`ζ = 𝓔(ξ)`, 146:10) relates them
globally, and TIU-Def-Ref instantiates a definition's scheme with fresh
variables at every use, copying whatever sets the scheme accumulated. There
is one constraint store, so "into", "across", and "out" are the same
unification.

Eco solves per-item stores (LSS_006 mints fresh arrow structure per load;
items are isolated). The trip therefore decomposes into FOUR links, each
needing an explicit mechanism, each independently measurable:

- **L-in** — the construction-site write: the stored function's member lands
  in the producer's local slots (arg injection, spine successors).
- **L-mirror** — in-item unification ties the written slot to every other
  position of the same value (field arrow ↔ type-argument arrow of the
  container; the body's plumbing).
- **L-across** — the knowledge crosses items: via the registry demand type
  (zonked at enqueue, joined per LSS_010) and/or the signature channel
  (facts at arrow ordinals, applied at instantiation).
- **L-out** — the consumer's registry position reads back a set (coverage),
  and the eventual application site can devirt (exploitation, recorded not
  gated).

## §1 What the provenance census says (2026-08-30 baseline: positions=140,435, coverage 89.20 %, var=13,029, top=2,125)

All numbers from `build-kernel/prov.log` (`pos|` rows now carry `top@<kind>`;
kinds shipped §4.9–4.10 of `lss-provenance-join-and-demand-sigs.md`).

### §1.1 The target mass is type-argument arrows, and it is HALF of all var

Positions whose path crosses a custom-type argument (`c<n>` segment):

| kind at c-paths | count |
|---|---|
| var | **7,361 (= 56.5 % of ALL var)** |
| k1 | 3,055 |
| top | 298 (decl 289, poison 8, conflict 1) |
| kN | 154 |

**98.6 % of the c-path var sits in 12 globals** — the compiler's own
applicative decode chain and its Result plumbing: `Decoder` 1,467, `apply`
1,430, `andThen` 1,379, `map` 1,358, `Ok` 730, `Err` 671, `pure` 64, folds ≈
170. (`pos|` drops the module; these aggregate Compiler/Json/Decode-style
modules plus core Result/List.)

### §1.2 The per-path shapes locate the break ONE HOP past the shipped machinery

From the same log (counts per (path, kind) on the hot globals):

- `map`: head k1 2,924; **`/a0` k1 2,836** (the callback itself is covered —
  `standaloneArgMember` + `injectPapSuccessors` work); `/a0/r` k1 205 BUT
  var 110; `/r/r/c1` k1 141 BUT var 68; `top` at `/a0/a0` 121 and
  `/r/a0/c1` 120.
- `Decoder` (the ctor): head k1 1,978, `/a0` k1 1,824 (the stored field
  arrow is covered); var starts at `/a0/r/c1…` and `/r/c1…` — arrows inside
  the RESULT TYPE ARGUMENT, i.e. decoders OF functions, with ~62/60/55/51
  rows per successive `/r` rung (the curried `pure Ctor |> apply …`
  pipeline, one rung per remaining ctor parameter).
- `Ok`: var at `/a0(…)` EXACTLY mirrored by `/r/c1(…)` — 62=62, 60=60,
  55=55, 51=51 per depth. `apply`: `/r/a0/c1…` mirrored by `/r/r/c1…`.

**Reading:** the head and direct-callback positions are healed by the
shipped default-on stack (refIdentity, regIdentity, papMembers, refPapSpine,
injTotal, rsTop). The remaining var is (a) the callback's RESULT spine — what
a partially-applied constructor still expects — and (b) its MIRROR inside the
container's type argument. The exact per-depth equality of the mirrored
counts is strong evidence the two paths are ALREADY UNIFIED in-store
(L-mirror works); they are never WRITTEN (var is 100 % causeFlex — the
2026-08-26 census) or the write dies at an item boundary.

### §1.3 The ctor-node ⊤s are the same story, not a spine story

`top sites`/`top kinds` cross: ctor-node ⊤ = 856, ALL nested — decl 549 +
poison 307. The old plan's spine-⊤ concern is dead (P1/rsTop-era machinery
plus the old P0 already showed head/spine ⊤s are storeless-classify stamps,
not missing injections). The decl 549 are `topDecl` placeholder stamps at
payload/type-arg positions (e.g. `Decoder|/a0` top 151 + `/a0/r` top 151);
⊤ is terminal — no write can heal it — so this slice needs PREVENTION
(don't stamp ⊤ where var is honest), recorded as P4, not attacked here.
The poison 307 is genuinely absorbed kernel-boundary ⊤ — out of scope.

### §1.4 What the residue is NOT

- Not budget/size widening (§4.7: limits now unlimited, widen counters 0).
- Not missing kernel licenses (unlicAlias = 4).
- Not the argument-head class (k1 at `/a0` across the family).
- Not a diffuse mass: 12 globals, one family shape.

## §2 The chain model, link by link, with code anchors

| link | mechanism today | status | evidence |
|---|---|---|---|
| L-in, reference args | `injectArgLambdaMember` VarGlobal/VarBox/VarCycle/Accessor/VarKernel arms: head member (`g|`/`c|`/`k|`) + `injectPapSuccessors` p-successors to declaredArity (Ctor arm exists: `TOpt.Ctor _ arity _`) | **SHIPPED, default-on** | `map\|/a0` k1 2,836; `refspine\|inject` counter |
| L-in, lambda args | `injectLambdaMemberQualified` at the literal's OWN param count; a lambda RETURNING a function leaves the `/r` rungs to the inner lambda's own walk (in-item tie only) | partial | `map\|/a0/r` var 110 |
| L-in, local/PAP-expression args | `enrichFromEnv` for plain locals; local-multi + applied-expression args = "known precision gap in v1" (docstring) | **GAP** | probe `ARGDIAG ("Call(TrackedVarLocal)", …)` from the M2 diagnosis |
| L-mirror | body unification inside the producer's item store | works (hypothesis: mirrored var counts §1.2; P0.c proves it) | Ok `/a0`≡`/r/c1` counts |
| L-across, demand route | enqueue zonk carries the caller's annos into the demand type; registry joins per LSS_010 | works where L-in wrote in the CALLER of that spec | k1 rows at c-paths (3,055) |
| L-across, signature route | `signatureFor` from CALL sites; M3.3 extends to container-typed REFERENCES, `instantiateWithSignature` + `unifyBestEffort`, **B1 fact-gated** (`sig0.trivial` skip) | **BUILT, PARKED** under `lss.argPoints` (default-off) | M3 probe: `consume2\|/a0/c0` var→k1; scale was −0.21 pp from key churn PRE-B1; B1 census: refSigSkipTrivial=814 / live=1 |
| L-out | census readback + AbiCloning devirt | free once demand types carry sets | — |

**The two load-bearing facts from the M3/B1 postmortem** (four-lever §7.4–7.5,
provenance plan §4.2): (1) the mechanism CLOSES the chain (probe-proven,
cross-item, ctor payload — first time); (2) the scale decline was NOT the
mechanism — it was trivial-signature instantiations renumbering vars and
splitting SpecKeys, which the B1 gate now provably eliminates (99.8 % of M3's
fires were trivial). And the recorded order stands: **producer sigs must
carry facts before reference-side instantiation pays** — "A-then-B". P1 (root
completion) is what makes producer sigs non-trivial; P2 (un-park the
crossing) then has something to transport.

## §3 Design

### P0 — chain attribution instruments + GO/NO-GO (measure, no mechanism)

- **P0.a `var@<id>` census rows.** Extend the posWalk census (5 lines,
  rides `lss.arrowCensus` like `top@<kind>`): var rows become
  `var@<flexId>`. One self-compile then answers GLOBALLY: (i) the L-mirror
  hypothesis — mirrored paths carry the SAME id (count distinct ids vs
  positions per global); (ii) cross-position sharing generally (a successor
  of the §1.2 62=62 observation). Sound because `LVar Int` already carries
  the store's canonical flex id.
- **P0.b Decoder-family probe** (`LssGapDecoderChain`): a minimal replica of
  the compiler's own applicative chain —
  `type D e a = D (Int -> Result e a)` + `pure`/`apply`/`map`/`andThen` +
  `type Pair = Pair Int Int` + `pure Pair |> apply dInt |> apply dInt` +
  run + destructure + CALL the decoded function. CHECK the runtime value;
  read `pos|` rows at defaults. Expected at defaults (falsifiable): root
  writes k1 at `map/apply` arg heads; var at the interior c-paths and the
  consumer; the probe names which link breaks first.
- **P0.c per-link toggles on the probe**: `ECO_MONO_LSS_ARG_POINTS=1` arm —
  does the crossing close the probe's consumer positions (the M3 result,
  reproduced at today's baseline)? Read `argpt|refSig*`/`argpt|refInst*`
  counters both arms.
- **P0.d corpus transport-candidate count** (from existing prov.log, no
  run): var-at-c-path positions whose (global, mirrored-path) sibling
  already holds k1 — the demand-route-reachable subset.
- **GO/NO-GO:** GO for P1 requires P0.b to show ≥1 root-class var (lambda-
  result rung or local/PAP arg) at the producer, and P0.a to confirm
  mirroring ≥50 % on the hot family. GO for P2 requires P0.c to close the
  probe's consumer var with argPoints on, at ZERO trivial-instantiation
  fires (B1 holding). NO-GO on either → write the finding, stop that phase.

### P1 — L-in root completion (REVISED BY §7 AR: the local-binding chain)

The §7 review killed two of the three originally-drafted components as
PHANTOMS (mechanisms that already exist and fire): lambda-literal args
self-cover in-item (the inner literal's own walk injects into the shared
expression slots, and LSS_013 FORBIDS stamping the outer member deeper), and
applied-PAP args are covered because the arg expression's own Call
translation runs `injectPapMember` (papMembers, default-on). What survives:

- **P1.a The let-bound local chain (translation side).** `_v0 = Pair 1;
  map _v0 d`: the RHS write exists (papInject), the question is whether it
  SURVIVES the binding: RHS zonk → `varEnv` MonoType → `enrichFromEnv`
  (which DOES encode full-type annotations via `monoTypeToVar`,
  Translate:4344 — verified §7 AR-v2-3) → arg slot. Laundering candidates,
  each with a P0 counter: (i) `varEnv` holds the DECLARED classify type
  instead of the RHS zonk; (ii) the RHS zonk runs BEFORE the injection
  lands; (iii) `isLocalMultiTarget` skips. FIX whichever counter convicts —
  this is a repair of an existing chain, not a new mechanism.
- **P1.b The inference-side twin (already built, parked).** The sig channel
  loses the same locals at `joinLetUse`'s guard arm — M3.1's family-point
  handoff (`Ok ( WpHonest rhsVar, s0 )`) fixed exactly this and sits under
  `lss.argPoints`. P1.b = evaluate flipping the M3.1+M2 inference-side arms
  (possibly split from M3.3 under their own sub-flag) so producer SIGNATURES
  see what translation sees — the A-then-B producer half.

Explicitly NOT in P1: new member namespaces, new injection arms for literal
or Call args (phantoms — pinned by P0.b instead), any write into ctor
CANONICAL slots (old-plan P2), anything touching `AssignMVarIds` or the
typed-artifacts codec (carried-over AR-1).

### P2 — L-across: un-park the crossing (existing `lss.argPoints`, staged)

With P1 making producer signatures non-trivial (A-then-B satisfied):

- **P2.a** Re-run the M3 scale A/B at today's baseline: defaults+P1 vs
  +`argPoints`. The B1 gate is already in the code; the 2026-08-29 decline
  mechanism (trivial-sig key churn) is measurably gone (`refSigSkipTrivial`
  dominating, `refInst` fact-gated). Gates: coverage ↑, spec-key population
  sane (createdSpecs per hot global vs baseline), E2E both arms.
- **P2.b** If a residue remains at ctor-VALUED container positions
  (`LssGapCtorInList`'s `runFirst|/a0/l` class): NOW consider the old plan's
  declaration-site `c|` injection (old §2.2) as the enabler that makes CTOR
  sigs non-trivial — under B1 it no longer churns keys. Old-plan §1/§2.2
  text remains the design reference; its P0 result (heads unaddressable,
  indirect class real) still binds.

### P3 — battery and flip decisions (per flag, standard legs)

Frozen-corpus byte-identity flag-off; probe battery (P0.b probe + the 20
LssGap probes + `LssGapCtorTypeArgFn`/`LssGapCtorInList`/`LssGapCtorAsValue`
expectations from the old plan's P0, restated in §8); self-compile census
A/B per flag (coverage is THE gate; `top kinds`/`top sites` must not move
except where predicted; var@c-paths is the headline); Q verifier both arms;
E2E + elm-tests both arms; dispatch recorded not gated.

### P4 — recorded, not designed here

- **tkDecl ⊤ prevention** at storeless-classify sites (§1.3's 549+289): the
  classify path stamps `topDecl` where `LVar` would be honest — but ⊤ vs var
  ride different key/encode channels (`annoKey` separates them), so this is
  a KEYING change with M1-class blast radius. Needs its own plan + P0.
- **Alias ctors** (old-plan P4): still deferred; detection options recorded
  in the old plan text (git history) — shape-match vs cache-format change vs
  accept.
- **Poison-in-ctor 307**: unreachable by transport (⊤ absorbs); only a
  licensing/per-callsite-transport story could touch it; measured, parked.

## §4 Success criteria

- Headline: **var at c-paths, self-compile** (baseline 7,361). P1+P2 target:
  the mirrored+transport-reachable subset per P0.a/P0.d — quote the measured
  bound, not the 7,361.
- Coverage (THE gate) strictly ↑ per flag flip; top does not rise; kinds
  stable (decl/poison/abi/conflict shares move only via predicted heals).
- The P0.b probe's consumer CALL devirts (exploitation witness, recorded).
- All shipped-flag batteries stay green (E2E 1,714, elm-tests known-12).

## §5 Paper fidelity

1. **Members for constructors and their partial applications.** Fig. 6's 𝒬
   injects EVERY function literal; constructors are literal functions of the
   program. Eco's `c|`/`g|` head members + `p|g|d` successors are 𝒬 applied
   to the conceptually-curried constructor at each spine depth — the
   `injectPapSuccessors` docstring's argument, already reviewed for
   refPapSpine and reused verbatim (no new class). P1.b extends WHERE the
   member is delivered (an argument position instead of a producer/reference
   position), not WHAT exists — the paper does not distinguish delivery
   sites; its sets are global.
2. **Arrows inside type arguments.** The paper's datatype arrows carry set
   variables like any other position; `ζ = 𝓔(ξ)` ties them through
   unification of the container type at construction and destructure. Eco's
   L-mirror (store unification inside the item) + LSS_010 demand joins are
   that same tie, split across the item boundary. Nothing in P1/P2 invents
   sets the paper would not have: every injected member names a function the
   value MAY be (soundness = injection completeness per class, the
   arrowSolverRoots lesson, §7 AR-v2-6).
3. **Instantiation at every use.** TIU-Def-Ref instantiates the scheme at
   every reference, copying accumulated sets. Eco historically instantiated
   signatures at CALLS only; M3.3 extends to container-typed references —
   this RESTORES paper behavior rather than extending it (the M3.3 comment
   says exactly this). The B1 trivial-skip is faithful: instantiating an
   all-default scheme is semantically the identity; skipping it changes no
   analysis result, only avoids Eco-specific SpecKey var-renumbering churn.
   (The paper has no spec keys — a paper-only argument would not even see
   the M3 regression.)
4. **What stays deliberately non-paper.** Per-item isolation, keyed
   registry, widened joins (LSet∪LVar=⊤) — Eco's standing departures,
   documented in `lss-paper-fidelity-mapping.md`; this plan narrows the gap
   they cause (never-written vars) without touching the lattice.

## §6 Carried-over constraints from the 2026-08-27 plan (still binding)

- **AR-1**: never stamp identity in `addCtorNode` — `Can.Type` slots ride
  the typed-artifacts cache codec.
- **AR-8**: `provBp` is diagnostic only; unreached synthesized ctors inflate
  it positionlessly. FORBIDDEN as a success number.
- **Old P0 result**: a def's OWN head/spine arrows are storeless-classify
  stamps — injection cannot flip them (now visible as tkDecl in the kind
  census); `useCtor|/a0`-class direct positions are ALREADY covered;
  the indirect class (`runFirst|/a0/l`) is real but was never corpus-sized —
  §1 now sizes the family it belongs to.
- **E9.2 one-identity**: every new delivery site must mint through
  `papMemberKey`/`standaloneMemberIdFor` interning — never a new namespace
  for the same value.
- **LSS_037**: every member write must be a Q-recorded constraint
  (`unifySlotWithSet` family only — no raw `UF.set`).

## §7 Adversarial review (v2) — run 2026-08-30 against code and the paper

**AR-v2-1 (kills draft P1.a — lambda-result successors are a phantom).**
`injectLambdaMember`'s contract (LssInfer:172 region): spine bounded at the
literal's OWN param count, "the spine is bounded there so a
function-returning body never stamps its returned closure's arrows" — the
LSS_013 licensing argument. A literal returning a literal is covered by the
INNER literal's own walk into the shared expression slots (same item, same
load). Injecting the outer member deeper would be UNSOUND (names the wrong
value); injecting the inner member from the outside is REDUNDANT. Draft
P1.a deleted; P0.b pins the literal-in-literal case as already-covered
instead (a probe row, not a mechanism).

**AR-v2-2 (kills draft P1.b — Call-arg arms are a phantom).** A partial
application in argument position is an EXPRESSION; its own translation runs
the Call path, and `injectPapMember` (Translate:4114, papMembers default-on)
injects `p|g|supplied` at the residual head + `injectPapSuccessorsFrom` (L2)
deeper, into slots the expression's typing shares with the arg's `canVar`.
Adding an arg-side arm would double-inject the same interned ids (idempotent
but dead code). The REAL break is the let-binding indirection the M2
diagnosis recorded verbatim (`ARGDIAG ("Call(TrackedVarLocal)", …, ["_v0"])`
— partial ctor apps are let-bound): the write lands in the RHS's slots; the
USE reloads fresh slots (LSS_006) and must be re-fed. Draft P1.b deleted;
survives as P1.a (the local chain).

**AR-v2-3 (confirms the local chain is full-type, so the gap is upstream).**
`enrichFromEnv` (Translate:4344): for a local arg, `Engine.lookupVar` →
`Store.monoTypeToVar boundType` → `unifyStepBestEffort canVar boundVar`.
`monoTypeToVar` encodes the bound MonoType's ANNOTATIONS into store content
(the §4.9-verified encode path: `LSet → LsMembers`, `LTop k → lsTopContentK`)
— NESTED positions included. So if the varEnv MonoType carries the sets, the
transport works; the var readings mean the MonoType does NOT carry them (or
local-multi skips). The three laundering candidates and their counters are
enumerated in P1.a; P0 convicts one before any fix is written.

**AR-v2-4 (the shipped machinery's reach, measured).** `refspine|inject` =
44,410 / `refspine|arity1` = 50,510 in prov.log — reference-spine successors
fire at scale, matching `map|/a0` k1=2,836 and `/a0/r` k1=205. All reference
forms have arms at defaults (VarGlobal/VarBox/VarCycle/Accessor/VarKernel,
Translate's injectArgLambdaMember; VarEnum vacuous — enums are arrow-free).
The `_ ->` wildcard covers exactly: locals, applied expressions, literals —
the first is P1.a's subject; the other two are AR-v2-1/-2's phantoms.

**AR-v2-5 (A-then-B mechanics made precise).** Producer signatures get their
facts from the producer's OWN inference walk (sig ordinals over
`sigSourceTypeFor`'s annotation copy; facts read from the item slots the
body unified with). Call-site writes in CALLERS feed the DEMAND route, not
the callee's signature. Therefore: P1.a (translation) heals the demand
route; P1.b (inference twin, M3.1/M2 arms) heals the signature route; P2's
reference-side instantiation (M3.3) only pays after the SIGNATURE route
carries facts — the recorded A-then-B order, now with the mechanism named.

**AR-v2-6 (soundness envelope, unchanged).** Every member this plan moves is
an ALREADY-MINTED interned id (`l|`, `p|g|d`, `c|`, `g|`) delivered to slots
its value genuinely inhabits; no new namespace, no new class. Injection
completeness per class is preserved because no arm is narrowed — only
laundering repairs (P1.a) and already-reviewed arms flipped (P1.b/P2). The
arrowSolverRoots false-singleton lesson does not bite: repairs ADD members
to sets, never merge classes. LSS_037 holds: all writes go through
`unifySlotWithSet`/`unifyStepBestEffort` (Q-recorded).

**AR-v2-7 (P0.a instrument validity).** `Mono.LVar` ids are minted by
`varNumberFor setVar` at zonk (Store:3151/3195) — canonical per SLOT within
one entry's zonk, NOT comparable across entries. The `var@<id>` census rows
must therefore carry an entry discriminator (`var@<entryIdx>.<vn>`), and the
mirror analysis groups per entry. Also note the alternative explanation for
the §1.2 mirrored counts: hash-consed SUBTREE SHARING (the same MonoType
subtree at both paths) — either way one write fills both readings, but the
instrument distinguishes them (shared subtree ⇒ same id trivially).

**AR-v2-8 (against the paper — fidelity confirmed on three points, one
Eco-only guard).** (1) Members for ctors and their PAPs at every spine depth
= Fig. 6's total 𝒬 over the conceptually-curried function — the argument
already reviewed and shipped for refPapSpine; this plan adds no new class,
only delivery repair. (2) Type-argument arrows carrying sets tied by
unification = `ζ = 𝓔(ξ)`; Eco's L-mirror + LSS_010 demand joins + signature
facts are that tie split across item boundaries; a repair that makes an
existing write ARRIVE cannot create a set the paper would not have. (3)
Reference-site instantiation (M3.3) = TIU-Def-Ref at every use — a
RESTORATION of paper behavior. (4) The B1 trivial-skip is Eco-only and
analysis-neutral: instantiating an all-default scheme is the identity on
knowledge; the paper has no SpecKeys to churn. Confirmed faithful: same
analysis, different arrival order.

**AR-v2-9 (risk register for P2).** The M3 scale regression mechanism
(trivial-sig var renumbering splitting SpecKeys) is measurably closed by B1
(`refSigSkipTrivial` 814/815). Remaining P2 risks: (a) non-trivial sigs
post-P1 make instantiation FIRE where it used to skip — watch
`createdSpecs` per hot global and compile wall both arms; (b) the
inference-side arms (M2 walked points) touch `unifyParamsWithPoints` —
byte-identity flag-off must gate as always; (c) `argPoints` bundles FOUR
sub-mechanisms — if the A/B is mixed, split the flag before deciding
(lowering pre-assigns the split: M3.1+M2 producer-side vs M3.2+M3.3
reference-side).

## §8 Implementation-ready lowering

Baseline calibration (prov.log, read 2026-08-30): `leak|letAnno = 57` (the
P1.a translation-side leak EXISTS but is small at event level — 57 bindings
per self-compile; each may starve many downstream positions, P0.b sizes the
fan-out), `papInject|pap = 3,619` (+ deep|d2 534) — producer writes fire at
scale. `argpt|*` absent at defaults (flag off) ✓. Weight accordingly: P1.a
is a small precise repair; **P2 (the crossing) is the mass lever**.

### §8.1 P0.a — census instruments (Monomorphize.elm + Translate.elm, census-only)

1. `posWalk` var arm (Monomorphize.elm ~line 731): emit
   `( path, "var@" ++ String.fromInt entryIdx ++ "." ++ String.fromInt vn )`
   for `Mono.LVar vn`. Thread `entryIdx`: posRows' `Array.foldl` over
   `g.registry.reverseMapping` becomes an indexed fold (the array index IS
   the spec id) — `Array.toIndexedList |> List.foldl`; pass the idx into the
   row builder only (posWalk itself unchanged — tag built at the map step
   is WRONG since kind is built inside posWalk; instead thread entryIdx as
   an extra posWalk argument OR post-process: keep posWalk emitting
   `var@<vn>` and prefix the entry idx at the `List.map` row-builder by
   string-replacing… cleanest: give posWalk an `entryTag : String` argument
   appended in the var arm only). `topSiteAndKindCounts` filter
   (`String.startsWith "top"`) unaffected; python analyses updated for the
   new var tag.
2. `enrichFromEnv` local arm (Translate.elm:4344): census-gated counters
   via `Engine.bumpArgFlowCensus` (internally report-gated):
   `enrich|withSets` when `not (List.isEmpty (Mono.collectAnnoMembers boundType))`,
   else `enrich|bare`; `enrich|localMulti` on the isLM skip;
   `enrich|unbound` on `Nothing`. Guard the collectAnnoMembers walk behind
   `s.env.lss.report` (allocation).
3. Rebuild (`--target eco-compiler`), one defaults census run (standard
   `prov.sh`-shape script). Deliverables: (a) mirror ratio — per entry, the
   fraction of var positions whose id appears at ≥2 paths (expect ≥50 % on
   the hot family per §1.2); (b) `enrich|bare` vs `withSets` (how starved
   the local chain is); (c) `leak|letAnno` restated.

### §8.2 P0.b — the family probe (test/elm/src/LssGapDecoderChain.elm)

```elm
module LssGapDecoderChain exposing (main)
-- CHECK: decoderChain: 9
import Html exposing (text)
type D e a = D (Int -> Result e a)
type Pair = Pair Int Int
pureD : a -> D e a
pureD a = D (\_ -> Ok a)
applyD : D e a -> D e (a -> b) -> D e b
applyD (D da) (D df) =
    D (\i -> case ( df i, da i ) of
            ( Ok f, Ok a ) -> Ok (f a)
            ( Err e, _ ) -> Err e
            ( _, Err e ) -> Err e)
dInt : Int -> D e Int
dInt n = D (\_ -> Ok n)
runD : D e a -> Result e a
runD (D f) = f 0
pairValue : Pair -> Int
pairValue (Pair a b) = a + b
main =
    let
        _ = Debug.log "decoderChain"
                (case runD (applyD (dInt 2) (applyD (dInt 7) (pureD Pair))) of
                    Ok p -> pairValue p
                    Err () -> -1)
    in
    text "h"
```

Compile (defaults + REPORT + ARROW_CENSUS, `rm -rf eco-stuff` first), lower,
RUN (CHECK 9 — the "clean lower ≠ correct" trap), read `pos|` rows.
Predictions to grade (falsifiable): `pureD|/a0` k1 (c|Pair head via arg
injection); `pureD|/a0/r`+successors k1 IF refspine covers ctor refs at arg
positions (AR-v2-4 says yes); the `applyD`/`D|…/c1…` interior and the
consumer positions var AT DEFAULTS; the SAME rows k1 with
`ECO_MONO_LSS_ARG_POINTS=1` (P0.c — the M3 result reproduced at today's
baseline). Any deviation rewrites §3 before mechanism work.

### §8.3 P0.d — corpus transport-candidate bound (post-P0.a rerun, python)

Group `var@<entry>.<vn>` rows per entry; count (i) var ids that appear at a
c-path AND a non-c path of the same entry (mirror pairs — one write fills
both), (ii) entries where a mirrored id coexists with a k1 at the same path
in ANOTHER entry of the same global (demand-route candidates). Report the
two bounds beside the raw 7,361.

### §8.4 P1.a — the letAnno overlay repair (contingent on P0)

Site: Translate.elm ~5186 (the `useBodyType` decision + `leak|letAnno`
census). Fix: when the classify wins (`not useBodyType`) and `bodyType`
carries members, store `Mono.overlayAnnotations defType bodyType` (exported;
structure from defType, annotations overlaid from bodyType where defType's
are var/⊤ — VERIFY its exact bias direction before use, it must never
DOWNGRADE a defType set) into varEnv instead of bare `defType`. Flag:
`lss.letAnnoOverlay` if measurable risk appears, else fold into P1's
`lss.ctorSpine`… naming now wrong — rename the P1 flag `lss.letOverlay`
(`ECO_MONO_LSS_LET_OVERLAY`, token `lssLO=`), default-off, 4-site Config
pattern + Builder override (copy the rsTop wiring verbatim, decoder field
APPENDED LAST). Unit differential: fixture with
`let f = P 1 in useBox (Box f)` — off: consumer var; on: k1 (TestPipeline
fixtures CAN express unions? VERIFY SourceBuilder supports type decls; if
not, E2E probe pins it instead).

### §8.5 P1.b/P2 — split the argPoints bundle, then stage the A/B

The 6 `argPoints` gates split cleanly:

- **producer side** (`lss.argPointsProd`, token `lssAPp=`): LssInfer:1373
  (walkCallWith point threading), :1447 (VarEnum/VarBox walked-point arms),
  :1860/:1867 (kernelCallBoundaryWith consumption), :3051 (joinLetUse
  family-point handoff — M3.1).
- **reference side** (`lss.argPointsRef`, token `lssAPr=`): LssInfer M3.2
  container-typed VarGlobal reference arm; Translate M3.3 arm (the B1-gated
  block, Translate ~1873 region).

Config: two new fields mirroring rsTop wiring; `lss.argPoints = True` in a
test/env sets BOTH (keep the old env var as a master alias — the Builder
override sets both fields; old tests unaffected). Battery order (A-then-B,
same binary, env A/B, serial, `rm -rf eco-stuff` per arm):

1. Arm P (Prod only): census — producer sig facts appear? (`sigfacts`
   non-trivial count, `argpt|` producer counters), coverage Δ, var@c Δ.
2. Arm P+R: the crossing. Watch `argpt|refInst` vs `refSigSkipTrivial`
   (B1 holding: skips ≫ fires pre-P1; fires grow with facts), createdSpecs
   per hot global (Decoder/apply/map/andThen) vs baseline — >+5 % specs on
   any hot global = investigate before believing coverage.
3. Probe battery both arms: LssGapDecoderChain, LssGapCtorTypeArgFn
   (consume2|/a0/c0 var→k1), LssGapCtorInList, LssGapCtorAsValue
   (no-regression), LssGapKernelPipeline + full E2E flag-on
   (touch test/elm/src — env-blind cache), elm-tests (known-12).
4. Q verifier both arms (`ECO_MONO_LSS_QCENSUS=1`): diverge=0.
5. Dispatch A/B recorded (Run-AO rail), not gated.
6. Flip decision per sub-flag on gate 0 (coverage ↑, no key blowup, suites
   green); commit.txt per flip, user decides.

### §8.6 Order of work — SUPERSEDED, kept for the record

The order below was written before P0 ran. P0 falsified §8.2's probe, the
attribution rounds (§9–§9.3) relocated the target twice, and `argFeedback`
was built, measured and reverted (§8.4-IMPLEMENTED / §8.7). The live plan is
now: **§9.3's next instrument** — compare the scrutinee's stored slot against
the storeless classify of the destructor-bound type — then a mechanism only if
that measurement shows k1 available.


P0.a instruments → P0 census run → P0.b/P0.c probe (+argPoints arm) →
P0.d analysis → GO/NO-GO table appended to this §  → P1.a repair (if
convicted) with its differential → §8.5 flag split → staged A/B → flip
decisions → P2.b (old-plan c|-injection) ONLY if the ctor-in-container
residue survives → P4 items to their own plans.

Estimated mass accounting to keep honest: healed positions must be traced
to (mirror pairs + demand-route + sig-route) bounds from P0.d — quoting
coverage Δ alone hides which link paid (the §4 rule).

### §8.0 P0 RESULTS (2026-08-30) — the probe falsified §8.2, the census
### relocated the target, and the mechanism found is ONE architectural gap

**P0.b v1 (`LssGapDecoderChain`) came back 100 % COVERED** (positions=50,
var=0, top=0, RUN=9 ✓). The applicative-over-a-custom-type shape is NOT the
failure; §1's reading of the corpus rows as "that shape" was wrong.

**P0.a (var@entry.vn rows) — the mirror hypothesis is CONFIRMED:** 13,029 var
positions carry only 7,727 distinct ids; 70.0 % sit in shared-id groups
(1.69 positions per missing write). Fixing one write heals ~1.7 positions.

**P0.d — the knowability split:** of the 1,189 (global,path) pairs holding
var, 396 have `k1`/`kN` in ANOTHER spec ⇒ **8,422 var positions (64.6 %) are
KNOWN-ELSEWHERE**; 4,607 (35.4 %) are never known anywhere. The top
known-elsewhere rows are `andThen|/a0/r` (475), `map3|/a0/r/r` (197),
`foldl|/a0/r` (162), `map|/a0/r` (110) — the CALLBACK RESULT SPINE, an arrow
position that exists only when a callback itself returns a function
(function-typed type aliases, transparent in MonoType). The never-known rows
are 8-10-rung `/r/r/r…` chains of the deep curried decode pipeline.

**P0.b v2 (`LssGapAliasCombinator`, written from that reading) REPRODUCES:**
coverage 82.75 %, `andThenP|/a0/r` var in every entry. Split into single-form
probes (`ZACCall`/`ZACLambda`/`ZACDirect`), ALL THREE callback forms fail
identically — including passing a global (`pureP`) whose OWN registry entry
reads `pureP|/r` = k1. The knowledge exists; it never arrives.

**P0 mechanism sizing (`argdeep|<form>|deep`, one self-compile):** argument
occurrences with a nameable position DEEPER than the injection covers —
**local 14,191, call 3,598, fn 773, ref 207** (flat: ref 17,549, fn 7,469).

**ROOT CAUSE (one gap, not four).** `argUnifyVar` loads the argument's
canonical type FRESH (LSS_006 mints new arrow structure per load) and
enriches only at the head; the argument's OWN translated type — carrying
everything its translation learned — is never fed back into the parameter
slot. `specializeLambda` has the same gap one level in: it computes the
lambda's type via `classifyLambdaHead` BEFORE translating the body, so a
lambda whose body returns a function records `var` at its own result.

**AR-v2-1 and AR-v2-2 were WRONG** (recorded honestly): they argued lambda
literals and applied-PAP arguments self-cover in-item. The probes show they
do not — the covering writes land in slots the fresh per-load structure
never shares. The corrected diagnosis is the feedback gap above, which
subsumes both cases without new member namespaces.

### §8.4-IMPLEMENTED — `lss.argFeedback` (default-off, env
### `ECO_MONO_LSS_ARG_FEEDBACK`, token `lssAF=`)

Two halves, both precision-monotone by construction:

1. **In-item (lambda):** `specializeLambda` merges the translated body's
   annotations into the lambda's own result spine via
   `Mono.enrichAnnotations` + `enrichLambdaResult` (peel `params` arrows,
   merge the rest). `enrichAnno` keeps whichever side names members and
   unions when both do — a set can never be downgraded, a ⊤ can never
   absorb a set. Structure is untouched, so the ABI codegen reads is
   unchanged.
2. **Cross-boundary (call args):** `ArgStash` gains `StashParam` carrying the
   callee's parameter slot; after `translateArgsWith` (and before the caller
   zonks `funcVar` into the demand), `feedbackArgSets` encodes each
   argument's own zonked type back into that slot —
   `Store.monoTypeToVar (Mono.deTopAnnos argType)` + best-effort unify.
   `deTopAnnos` rewrites the argument's ⊤s to fresh var numbers so a
   placeholder ⊤ can never absorb a parameter position the callee's
   signature had already resolved; `hasSetAnno` skips the whole path when
   the argument carries no sets (the common case — 162,446 skips vs 25,886
   feeds per self-compile).

**Micro-gate (probes, RUN-verified):** `ZACLambda` `/a0/r` var → **k1**,
coverage 93.33 % → **100 %**, runtime value unchanged. `ZACCall` and
`ZACDirect` do NOT move — their missing fact lives in the CALLEE's signature
(the returned-closure result fact), which is the L-across signature route,
not this mechanism. Honest scope limit, measured rather than argued.

**Scale A/B (same binary, self-compile, env A/B):**

| | off | on | Δ |
|---|---|---|---|
| coverage | 88.99 % | **89.39 %** | **+0.40 pp** |
| var | 13,388 | 12,776 | **−612** |
| k1 | 95,818 | 95,736 | −82 |
| kN | 29,609 | 30,292 | +683 |
| top | 2,127 | 2,172 | +45 |
| wall | 7:36.4 | 7:43.0 | +1.4 % |

Gate 0 (coverage must rise) PASSES. Two honest costs, both visible only
because the ⊤-kind census exists: the +45 ⊤ are **entirely `conflict`**
(elm 111→152, cycle 1→6) — the `LSet ∪ LVar = ⊤` join firing where one call
site now knows and another still does not, i.e. the Part-C lattice hazard,
not a defect in this mechanism; and −82 k1 is set growth (singletons
becoming honest multi-sets), dispatch-relevant and recorded, not gated.

### §8.5-MEASURED — the signature route is INERT, and why (A-then-B refuted)

Ran the plan's A-then-B step as a same-binary env A/B on top of
`argFeedback`: `argFeedback` vs `argFeedback + argPoints`. Result:
**byte-identical census** — coverage 89.39 % both, every `top kinds` cell
equal, wall within noise. Counters: `refSigSkipTrivial=814`,
`refSigLive=1`, `refInstSkip=585`, `refInst=1`.

The reason is in the same log: `signatures: 10033 memoized (8431 trivial)` —
**84 % of all signatures are trivial, UNCHANGED by argFeedback**. The A-then-B
premise ("P1 makes producer signatures non-trivial, so the reference-side
transport finally has facts to carry") is FALSE for this mechanism:
`argFeedback` is translation-side and enriches DEMAND types (registry
entries); signatures are computed by the producer's own INFERENCE walk
(`LssInfer`), a separate channel it never touches. So the B1 gate correctly
skips ~99.9 % of instantiations and the route stays inert — neither harmful
(the 2026-08-29 −0.21 pp regression is gone, as B1 predicted) nor useful.

**Verdict:** `lss.argPoints` stays DEFAULT-OFF and is now measured-inert
rather than measured-harmful. Making it pay requires an INFERENCE-side twin
of the feedback (the producer half proper) — the lambda-body → lambda-result
point handoff inside `LssInfer`'s walk, of which M3.1's `joinLetUse` arm is
one instance. That is a separate mechanism with its own P0, not a flag flip;
recorded here as the next lever rather than attempted.

### §8.7 Battery results (2026-08-30)

- **E2E:** 1,719/1,719 flag-ON and flag-OFF (the one failure in the first run
  was a leftover scratch probe, failing identically in both arms — deleted).
- **elm-tests:** 13,391 / 12 known-baseline, including the 4 new pins in
  `LssArgFeedbackTest` (off-vs-on differential at `/a0/r`, head-invariance,
  `enrichAnnotations` monotonicity, `deTopAnnos` freshness).
- **Probes kept:** `LssGapAliasCombinator` (the reproducing shape, CHECK 12,
  covers viaCall/viaLambda/viaLocal) and `LssGapDecoderChain` (the
  100 %-covered control — pins that the applicative shape stays covered).
- **Flip decision:** `lss.argFeedback` PASSES gate 0 (coverage +0.40 pp,
  var −612, suites green) at a recorded cost of +45 conflict-⊤, −82 k1
  (set growth) and +1.4 % wall. Left DEFAULT-OFF for the user's decision,
  per §8.5 step 6.

### §9 DECL-⊤ ATTRIBUTION (2026-08-30) — one site, two constructors

`argFeedback` REVERTED first (flag, both halves, its test) after the honest
review: it moved the plan's own stated target (c-path var) by **−9 of 7,636**
and `decl|ctor` by **zero**, converting var into kN while k1 FELL 82 — a
coverage-metric win, not a capability win. Recorded as a negative result.

`tkDecl` then split by manufacturing site into `declZonk` (Zonk's storeless
classify + Store's two curried builders), `declScheme` (TypeSubst),
`declKey` (Translate's SpecKey memo), `declSpec` (Specialize) — 11 stamp sites
retagged across 5 files, kind codes renumbered (synth 9, legacy 10) with the
store's per-kind CAF table extended.

**Result — every single decl ⊤ is `declZonk`:**

| sub-kind | count |
|---|---|
| declZonk | **1,233 (100 %)** — ctor 549, elm 489, cycle 142, accessor 38, licAlias 15 |
| declScheme | 0 |
| declKey | 0 |
| declSpec | 0 |

So TypeSubst's scheme builder, the SpecKey memo and Specialize manufacture
NOTHING that survives; the entire class is the storeless classification path
— the one whose own comment says its output "is unconditionally discarded
HERE in the solver path". For 1,233 positions it demonstrably is not.

**The ctor half is TWO constructors.** Per-global decl positions:
`Eerr` 264, `Cerr` 264 (528 = 96 % of the ctor 549), then `map` 246,
`foldl` 72, `toErr` 34, `composeL` 31, `andThen` 26. And
`Compiler/Parse/Primitives.elm:94` says what they are:

    type PStep x a = Cok a State | Eok a State
                   | Cerr Row Col (Row -> Col -> x)
                   | Eerr Row Col (Row -> Col -> x)

— the parser's error constructors, whose third field is a DEFERRED ERROR
BUILDER closure. Those payload arrows are the ⊤s. The same two globals carry
2,711 k1 and 196 var positions, so the machinery works on them generally;
the ⊤ is a specific un-overlaid subset.

**Verdict on feasibility:** prevention is now a single, narrow question —
why does the classify placeholder survive at these positions instead of being
replaced by the store zonk (`overlayAnnotations` takes structure from classify
and annotations from the zonk, and bails to `structural` on shape mismatch)?
That is a bounded investigation against ONE code path, not the diffuse
"⊤ is terminal, needs prevention" hand-wave §1.3 deferred. Open next steps,
in order: (a) split `declZonk` three ways to pin Zonk.elm:224 vs Store's two
curried builders; (b) trace one `Cerr` payload position from construction
site to registry entry and find where the overlay declines.

### §9.1 The decl-⊤ manufacturer, isolated to one line and one source pattern

**3-way split result — it is NOT the storeless classify entry point I named.**
Retagging `declZonk` into Zonk's `canTypeToMonoWithI` vs Store's two curried
builders gives: `declZonk` **0**, `declStoreC` **0**, `declStoreS` **1,233
(100 %)**. Every decl ⊤ in the self-compile is manufactured at ONE line —
`Store.elm:3611`, the `Can.TLambda` arm of `classifyGo` (the worker behind
`Store.classifyDirect`, i.e. Translate's `classify`):

    Can.TLambda _ from to ->
        ... Ok (Engine.consS (Mono.mFunction Mono.topDeclStoreS [ mFrom ] mTo) s2)

Note the asymmetry that makes this a defect rather than a limitation: the
`Can.TVar` arm immediately above it **does** consult the store
(`zonkToMono pt s` when the var is in the item memo); the `TLambda` arm never
does. Arrows are stamped ⊤ unconditionally even when the store holds a set
for that very slot.

**Who calls it:** `classify` supplies the RESULT MonoType of composite
expressions — `Case` (Translate.elm:841), `If` (673), `Let`, literals — so
any arrow NESTED inside a case/if result type is stamped ⊤.

**Trace of the real 528:** `Compiler/Parse/Primitives.elm:157`, inside the
generic `map`:

    case parser state of
        Cerr r c t -> Cerr r c t
        Eerr r c t -> Eerr r c t

The case's result type is `PStep x b`, whose `Cerr`/`Eerr` payload is
`(Row -> Col -> x)`. Classified storelessly ⇒ ⊤. The split is per-SPEC, which
the census confirms: at `Cerr|/r/r/a0` **172 specs read k1 and 132 read ⊤**
(same at `/r/r/a0/r`), i.e. the position is perfectly knowable — construction
sites that avoid a `case` get it, sites that go through one lose it.

**Minimal reproduction — `test/elm/src/LssGapCtorRebuild.elm`** (CHECK 33,
4 rungs, in the E2E suite). Single-rung bisect:

| rung | coverage | ⊤ |
|---|---|---|
| **rebuilt** (destructure + rebuild in a generic `case`) | 93.75 % | **1 × `Cerr2\|/r/a0\|top@declStoreS`** |
| direct (ctor applied to a literal lambda in situ) | 100 % | 0 |
| viaId (through a polymorphic identity) | 100 % | 0 |
| wrapped (generic `a -> Box a` at a function type) | 100 % | 0 |

16 positions, one ⊤, reproduced from source — small enough to lower and read
the MLIR for.

**Fix shape, with precedent — NOT yet built.** This is the same defect
`classifyRef` already fixed for bare references: it takes the store-aware
route (`loadType` → inject → `zonkToMono`) when `canTypeMentionsArrow`, and
its own docstring says the storeless answer "poisoned [arrows] before any
member could reach them". That flag (`refIdentity`) shipped for +7.14 pp. The
analogous repair here is to route composite result types through the store
when their type mentions an arrow.

**Measure BEFORE building (the argFeedback lesson):** ⊤→var is not a win by
itself — it converts a terminal unknown into a recoverable one. The open
question is whether the store actually HOLDS a set at that slot when the case
is classified; if it does not, a store-aware classify buys a var, not a k1.
Success criterion must be **k1 at these specific positions**, not a coverage
delta.

### §9.2 Does anyone know what the classifier discarded? — MEASURED

Instrument: `caseAnnoCensus` (Translate.elm, report-gated, pure) compares the
`case`'s CLASSIFIED result type against every translated branch, position by
position. First cut walked only `jumps` and saw 2 cells corpus-wide — a
simple case inlines its arms into the DECIDER (`Mono.Inline`) and leaves
`jumps` empty; the corrected walk covers both homes.

**Self-compile, `caseanno|<classified>|<branch>`:**

| classified | branch | count | reading |
|---|---|---|---|
| var | var | 2,986 | neither knows (the classifier's TVar arm zonked; still unwritten) |
| k1 | k1 | 1,008 | already agreed — the TVar arm's store read works |
| **top** | **top** | **644** | ⊤ stamped AND the branch has nothing better |
| **top** | **k1** | **163** | **⊤ stamped over a branch that names ONE inhabitant** |
| **top** | **kN** | **17** | ⊤ stamped over a known multi-set |
| top | var | 14 | ⊤ stamped over an unknown — relabel only |
| kN | kN | 78 | agreed |

**Answer: partially, and the ceiling is small.** Of the 838 ⊤-classified
positions at case sites, **180 (21 %) have a branch with a better answer, and
163 of those are singletons** — the k1 currency §10/L1 says to measure. The
other **644 (77 %) are ⊤ on both sides**: the branches are no better informed,
so repairing `classify` there relabels nothing. A store-aware/branch-merging
classify is therefore worth at most ~163 k1 at case sites, NOT the 1,233
`declStoreS` positions — the class is manufactured in one place but is not
recoverable from one place.

Note the classifier is already half store-aware and it shows: the
`k1|k1` 1,008 and `var|var` 2,986 rows exist only because `classifyGo`'s
`Can.TVar` arm reads the item memo and zonks. It is specifically the
`Can.TLambda` arm that discards.

**LOOSE END, stated not papered over:** the minimal repro
(`LssGapCtorRebuild.elm`) emits NO `caseanno` cell, so its single
`Cerr2|/r/a0|top@declStoreS` is manufactured by a `classify` caller OTHER than
`Case` — `Let`, a literal, or the destructor path. The 4-way/3-way kind split
technique applies directly: tag `classify`'s CALLERS (not its internals) and
re-run. Until that is done, "the case-rebuild pattern" is the shape that
reproduces the ⊤, not a proven attribution of which caller stamps it.

### §9.3 Caller attribution — it is the DESTRUCTOR, not the case result

`classify`'s ~44 call sites tagged by CALLER CLASS (`Store.classifyGo` now
takes the ⊤ kind to stamp; `Translate.classifyAs` supplies it). Iterated three
times until the untagged residue reached ZERO — the first two rounds left
1,225 then 1,012 unattributed, and chasing that residue is what found the
answer.

**Self-compile, all 1,233 decl ⊤ attributed:**

| caller class | count | share | site split |
|---|---|---|---|
| **clsDestr** (`TOpt.Destruct` / destructor path) | **1,012** | **82 %** | ctor 545, elm 385, cycle 70, licAlias 12 |
| clsLet | 174 | 14 % | cycle 72, elm 95, ctor 4, licAlias 3 |
| clsMisc (accessor) | 38 | 3 % | accessor 38 |
| clsLocal (`VarLocal`) | 8 | 0.6 % | elm 8 |
| clsCall | 1 | — | elm 1 |
| **clsCase, clsIf, clsLit, clsParam, clsLambda** | **0** | — | — |

**§9.1's attribution was WRONG and §9.2 measured the wrong site.** The case
result contributes ZERO surviving ⊤. The minimal repro's single ⊤ is
`top@clsDestr`, not a case: it is the DESTRUCTURING that loses the set, not
the rebuilding. `case ps of Cerr2 r t -> Cerr2 r t` fails because binding `t`
classifies its type `(Int -> x)` storelessly, and that ⊤ then rides the
rebuilt constructor into the demand. The source shape in §9.1 reproduces the
bug for the right reason but under the wrong name.

Per-global: `Eerr` 264 + `Cerr` 264 + `map` 241 + `toErr` 34 + `composeL` 31 +
`foldl` 46 + `foldrHelper`/`foldr` 20 each — every one a
destructure-a-function-payload site.

**Why this target is better than the case-result one §9.2 priced.** At case
results 77 % of ⊤ had no better answer available (branches were ⊤ too). A
destructor is different in kind: the value being destructured was CONSTRUCTED
somewhere with a known payload, and the scrutinee is already in the store
(it was just translated). The information plausibly exists at the exact
moment it is discarded — which is what §9.2 measured and did not find at the
case result. The equivalent measurement for the destructor path (compare the
scrutinee's stored slot against the storeless classify of the bound type) is
the next instrument, and it must be run BEFORE any mechanism: ⊤→var is not
payoff (§10/L6), and the success criterion is k1 at these positions.

**Cost of the instrumentation:** none observable — coverage, top, and the
kind totals are identical across all three attribution runs (positions
≈140,500, top 2,125), confirming the ⊤-kind codes stay semantically inert.

### §9.4 The destructor measurement — two channels, and the census separates
### channel capability from knowledge existence

Instrument: `destranno|<classified>|<projected>` at `specializeDestructor` —
the storeless classified type (which wins today) against
`Mono.getMonoPathType monoPath` (the root's varEnv type projected down the
path). Self-compile:

| classified | projected | count |
|---|---|---|
| top | **k1** | **125** |
| top | var | 76 |
| top | top | **14,187** |
| var | var | 1,448 |
| k1 | k1 | 513 |
| kN | kN | 59 |

Probe: `top|k1` = 1, `top|top` = 2.

**Reading this WRONG is easy, so the mechanics first.** The projection is
`computeCustomFieldType` → `instantiateUnionType` → `Zonk.canTypeToMonoWithI`
with a subst of the container's MONO type args. Its TVar arm returns the
substituted mono type WITH its annotations; its arrow arm (`lambdaChain`)
MINTS `topDeclZonk` (that path's arrows never survive to the registry, which
is why the §9 split showed declZonk = 0). Consequence, verified on the probe:

- A payload that IS the type variable (`Box a` at `a := fn` — the unbox
  class): the arrow arrives via substitution, annotations intact →
  projected k1. The probe's one `top|k1` is `unBox`'s `g`.
- A payload whose arrows are SYNTACTIC in the field type
  (`Cerr : … (Row -> Col -> x)`): the head arrows are minted ⊤ by the
  projection itself → `top|top` REGARDLESS of what anyone knows. The
  probe's `mapPS`/`runPS` `t` bindings are the two `top|top` cells.

So **`top|top` = 14,187 measures the CHANNEL, not the knowledge**: the
projection can only carry type-argument-borne sets. The 125 is channel A's
whole yield; the `Eerr`/`Cerr`/`map` class (the 82 % attribution) has
syntactic payload arrows and needs a second channel entirely.

**Where the knowledge for channel B lives (paper-guided).** In the paper,
`case ps of Cerr r c t` instantiates the ctor's scheme at ps's type with
fresh set variables, and those variables were already unified — through the
ONE global store — with every construction site's payload. Eco's equivalent
of "the ctor's scheme instance, globally unified" is the ctor global's
REGISTRY DEMAND: construction sites with arrow-bearing args always take the
slow path (`lssFastOk` fails on any arrow-typed arg), whose
`injectArgLambdaMember`/`enrichFromEnv` writes land in the demand zonk. The
destructure-side read of that knowledge is the **union over the ctor's
specs** of the demand annotation at the field position.

**The probe's multiplier in miniature (why the fix must be join-shaped).**
The probe's surviving ⊤ (`Cerr2|/r/a0`, the ctor's own registry row) is
manufactured by PROPAGATION: `t` binds ⊤ (channel-B position) → varEnv → the
rebuilt `Cerr2 r t` call's arg → `enrichFromEnv` encodes ⊤ →
`monoTypeToVar` writes `lsTopContentK` → the rebuild spec's demand joins ⊤ —
while the probe's three OTHER `Cerr2` specs read k1. One destructor-⊤,
via one rebuild, poisons one spec; at corpus scale, 1,012 registry positions.

### §9.5 The fixes, adversarially reviewed against code and paper

**FIX A — projection-borne annotations at the destructor (channel A).**
At `specializeDestructor` (and the `Engine.insertVar destructorName` that
feeds the body's varEnv), merge the projected type's annotations into the
classified type with PRECISION-MONOTONE semantics: a set wins over ⊤/var,
sets union, nothing else changes — i.e. re-land `enrichAnnotations` (built
and pin-tested in the argFeedback arc, reverted with it, §8.7). Structure
stays the classified one.

**FIX B — ctor-demand-union recovery for syntactic payload arrows (channel
B), applied LATE at the completion join.** For a registry entry whose
position reads ⊤ at a ctor FIELD arrow, recover the annotation from the
union, over all specs of that ctor global, of the demand annotation at the
same position — the `rsTop` recovery pattern (§4.10 of the provenance plan,
shipped, convergence proven) with a different knowledge source. Late
application is load-bearing: read-at-destructure is ORDER-SENSITIVE (a
destructor translated before the constructions see an empty union, stamps ⊤,
and ⊤ cannot be un-stamped — the paper's global fixpoint has no such order;
the completion join is Eco's one order-free window).

**AR-D1 (code) — the propagation multiplier means Fix A's static floor
understates it.** 125 events is the count where the projection knows TODAY,
with roots whose own varEnv types are ⊤-poisoned by upstream destructors.
Healing leaf destructors improves roots downstream — the cascade is
invisible to a static census and only the flag A/B measures it. Equally
honestly: A does NOT heal the probe (its cells are top|top), so A alone
must not be sold on the Eerr/Cerr class.

**AR-D2 (code) — Fix B's soundness rests on two verified facts plus one
audit obligation.** (1) Union-over-specs can only WIDEN — the miscompile
direction is false narrowing, so aggregation is conservative (worst case kN
instead of k1). (2) A construction whose payload carries an arrow CANNOT
take the storeless fast path: `lssFastOk` returns False when any arg's
canonical type has an arrow (Translate:2807 region, verified) — so every
construction that could contribute a member reaches the slow path's
demand-annotating machinery. (3) OBLIGATION: the slow path must actually
inject for every arg FORM (literals ✓ `injectLambdaMemberQualified`,
references ✓ head+successors, locals = `enrichFromEnv` transport — which
carries whatever varEnv has, including honest ⊤). A local-borne ⊤ in the
union keeps the recovery OFF at that position (⊤ ∪ anything = ⊤) — Fix B
degrades to no-op exactly where completeness is unproven. That is the safe
direction, and it is also why B's yield needs its own instrument (§9.6 P0)
rather than an estimate.

**AR-D3 (code) — the ⊤-spec circularity resolves through B's own fixpoint
direction.** Rebuild-shaped specs (the probe's fourth `Cerr2` spec) are
⊤-demand BECAUSE of the destructor ⊤ — including them in the union yields ⊤
and no recovery, forever. Fix B must therefore compute the union over
demand annotations EXCLUDING entries whose ⊤ is `clsDestr`-kinded — this is
the first mechanism to consume the §4.9 provenance kinds semantically…
which the §4.9 neutrality contract FORBIDS (kinds must never influence
analysis results). Resolution, and it is cleaner anyway: exclude nothing;
instead iterate — at completion-join time the rebuild spec's OWN demand was
built from a destructor that ran EARLIER in the same fixpoint, and after
Fix A+B heal the leaf generations, later joins see improved unions. Accept
the residue the first fixpoint leaves; measure it; do NOT special-case on
kinds. (Recorded so the tempting kind-consult is never built: it would make
census metadata load-bearing, the exact hazard §4.9 was designed out of.)

**AR-D4 (paper) — both fixes RESTORE the paper's analysis; neither extends
it.** The mapping doc's own rows carry the argument: F "annotates with
fresh set variables per node" and is implemented by `loadTypeC`'s freshness
(FAITHFUL row, §3.2); TIU unifies them through instantiated schemes
(FAITHFUL row). The destructor path today does NEITHER — it emits a
hardcoded ⊤, a construct the paper's grammar does not contain (the §3.1
"no ⊤ in the grammar — DIVERGENT" row). Fix A is exactly TIU's
substitution: annotations riding the instantiated type arguments of the
scrutinee's type. Fix B is the paper's global-store resolution of the
scheme's payload σ, reassembled from Eco's keyed shards by union — the
union IS the paper's unsplit view (the keying is Eco-only; GAP-2's
"signatures are ground" note covers the same reassembly direction).
LSS_002's containment invariant ("every reachable closure's head annotation
is ⊤ or contains its member") is preserved by both: A copies annotations
that already satisfied it at the root; B unions annotations that satisfied
it per-spec. Neither invents a member; neither narrows a set.

**AR-D5 (code) — MONO_029/layout safety.** Both fixes touch ANNOTATIONS
only; structure remains the storeless classification (the byte-path ABI
truth — `overlayAnnotations`' guard comment, and the reason `enrich` keeps
the structural side on any mismatch). The MonoDestructor's recorded type,
the varEnv binding, and the registry entry all keep their shapes.
`ValidateLayout` (`ECO_MONO_VALIDATE=1`) is the belt-and-braces leg in the
battery.

**AR-D6 (code) — where Fix B reads from is the SAME table §9.4's projection
could not use.** The ctor's specs live in the registry
(`registry.reverseMapping`, SpecKey = ctor global); at completion-join time
they are being finalized concurrently with the joining spec. Reading a
sibling entry mid-flight gets whatever its LAST join wrote — monotone
(demands only grow), so a stale read UNDER-recovers, never over-recovers.
Same argument rsTop's AR made for its stored-type read.

### §9.6 Lowering to implementation-ready detail

**Flag:** one flag for both fixes, `lss.destrAnno`
(`ECO_MONO_LSS_DESTR_ANNO`, token `lssDA=`), default-off, standard 4-site
Config pattern (decoder row LAST; copy the rsTop wiring). Artifact-affecting
when on (demand keys move).

**Step 1 — re-land `enrichAnnotations`** in `Compiler/AST/Monomorphized.elm`
exactly as shipped in the argFeedback arc (git history of 2026-08-30, or the
§8.4-IMPLEMENTED description): `enrichAnnotations`/`enrichAnno`, exported.
Its three unit pins from `LssArgFeedbackTest` return with it (monotonicity,
never-downgrade, structure preservation) in a new
`tests/TestLogic/Monomorphize/LssDestrAnnoTest.elm`.

**Step 2 — Fix A at the two destructor sites** (Translate.elm):

  - `specializeDestructor`: after the census call, when the flag is on,
    `monoType1 = Mono.enrichAnnotations monoType (Mono.getMonoPathType
    monoPath)`; `MonoDestructor name monoPath monoType1`.
  - The `TOpt.Destruct` arm's `Engine.insertVar destructorName
    destructorType` picks up `monoType1` automatically if it reads the
    destructor's recorded type — VERIFY it does (it destructures
    `Mono.MonoDestructor _ _ destructorType`); if it re-derives, apply the
    same enrich there.
  - The number-multi path (`specializeNumberDestruct`) keeps its scalar
    `eagerLeaf` machinery untouched — scalars carry no annotations.

**Step 3 — Fix B at the completion join** (Monomorphize.elm, beside the
rsTop recovery, same let-block):

  - New `Mono.recoverFromCtorDemands : (SpecKey -> List MonoType) -> MonoType
    -> ( MonoType, Int )` — walk the joined type; at each `MCustom home name
    args` position, for each ⊤-annotated arrow at a FIELD-projected position…
    STOP: field positions are not visible in the registry TYPE (only type
    args are). Fix B's walk therefore operates on the CTOR'S OWN entries —
    the target population is `Cerr|/r/r/a0`-class rows, i.e. positions
    INSIDE THE CTOR GLOBAL'S OWN demand type. Concretely: when the
    completing spec's key is a ctor global (node is `TOpt.Ctor`/`Box` — the
    `topSiteClassOf` classifier's `ctor` arm, reusable), take the union of
    THIS ctor's OTHER specs' demand annotations position-wise
    (`Mono.enrichAnnotations` with a pre-unioned source built by folding the
    sibling entries through `Mono.joinAnnotations`… NO — join ⊤-absorbs.
    Fold with `enrichAnnotations` itself: set-biased union, ⊤ contributes
    nothing) and enrich the joined type before the L1 stamp, mirroring
    rsTop's placement. Census counter `destrB|recovered`.
  - Sibling enumeration: `Registry` needs a specs-by-global lookup — check
    for an existing index (`specCountByGlobal` exists in S; the registry's
    key→id map can filter by global comparable prefix); if a scan is needed,
    gate it to ctor-node completions only (rare class).

**Step 4 — P0 for Fix B's yield BEFORE building step 3** (the census-first
rule): a report-gated cell at ctor completions — for each ⊤ position in the
joining entry, does the sibling-union hold a set? `destrB|would|<k1|kN|no>`.
One self-compile run decides whether step 3 is built at all. GO: `would|k1 +
would|kN` ≥ 300 (covers the majority of the 549 ctor decl-⊤). NO-GO: record,
park Fix B, ship Fix A alone if its own A/B clears gate 0.

**Step 5 — battery** (per flag arm, serial): byte-identity flag-off on the
frozen probes; probe expectations — `LssGapCtorRebuild` `Cerr2|/r/a0`
var→…→k1 needs BOTH fixes (predict: A alone leaves it, A+B heals it — the
falsifiable split); self-compile A/B quoting **k1 at the named globals**
(`Eerr`/`Cerr`/`map` rows) FIRST and coverage second (§10/L1); `top kinds`
delta (decl falls, conflict must NOT rise — the argFeedback tripwire);
`ECO_MONO_VALIDATE=1` leg (AR-D5); E2E + elm-tests both arms; dispatch
recorded. Flip decision per gate 0 with the user.

**Success criterion, verbatim from §10/L1:** k1 gained at
`Eerr`/`Cerr`/`map`/`foldl` destructor-fed positions and at the 528-row ctor
class — NOT the coverage headline, NOT var→kN conversion.

### §9.7 IMPLEMENTED AND MEASURED — `lss.destrAnno` (default-off)

**P0 outcome (GO):** `destrBend: k1=0 kN=830 no=0` — 830 ≥ 300, every ⊤
position at ctor entries has a set in the sibling union (including the
poison-kinded ones — recovery is kind-blind per AR-D3, and union-widening
makes that sound). The translation-time floor `destrBnow` saw sets at 2,696
of 2,733 ⊤-events (98.6 %): **floor ≈ ceiling**, so Fix B moved from the
settle-time design to the DESTRUCTOR itself — where it feeds `varEnv` and
the apply sites (the exploitation-relevant position), and where both fixes
become one edit. An early read that misses leaves today's ⊤: sound,
monotone.

**Implementation:** `Engine.SpecTally` — `specCountByGlobal` widened from
`Dict String Int` to `{count, ids}` (no new `S` field — the 32-slot GC-scan
cap trap) so `ctorFieldUnion` is O(specs-of-this-ctor); both fixes in
`specializeDestructor` behind `lss.destrAnno` (`lssDA=`), gated on
`hasTopAnno`; `enrichAnnotations` re-landed with its purity pins
(`LssDestrAnnoTest`).

**Probe micro-gate:** `Cerr2|/r/a0` ⊤ → set, probe 96.96 % → **100 %**,
RUN value unchanged (33). The §9.6 falsifiable split confirmed: A alone
left it, A+B heals it.

**Corpus A/B (same binary, env arms):**

| | off | on | Δ |
|---|---|---|---|
| top | 2,131 | **1,455** | **−676 (−32 %) — the largest ⊤ cut of the arc** |
| clsDestr\|ctor | 545 | **23** | −522 (96 % healed) |
| clsDestr\|elm | 387 | 233 | −154 |
| conflict | 112 | **112** | **0 — the argFeedback tripwire did NOT fire** |
| k1 | 95,865 | 96,994 | **+1,129 (k1 GREW — unlike argFeedback)** |
| kN | 29,628 | 31,035 | +1,407 |
| var | 13,389 | 13,389 | 0 (by design) |
| coverage | 88.99 % | 89.61 % | +0.62 pp |
| wall | 7:33 | 7:43 | +2.2 % (the union reads) |

**Named rows (the §10/L1 currency, k1 / top):** `Eerr` 1515→2028 / 264→2;
`Cerr` 1196→1724 / 264→4; `map` 6661→6775 / 307→193. `foldl`/`Decoder`/`Ok`
unmoved — their ⊤/var is poison-, let- and never-written-class, correctly
out of this mechanism's scope.

**Gates:** `ECO_MONO_VALIDATE=1` leg clean (MONO_029/AR-D5); E2E
**1,717/1,717 BOTH arms**; elm-tests at known-12 after one fixture repair —
the differential's first version asserted on `useBox|/a0/c0`, a position the
off-arm never poisons (reference transport covers it); the fixture now
mirrors the probe's REBUILD pattern and observes `Box`'s own registry rows.

**Honest residue:** clsDestr|elm 233 + clsDestr|cycle 70 remain (roots whose
varEnv types are themselves unannotated — deeper chains); poison/abi/conflict
untouched by construction. Flip decision with the user; dispatch A/B not yet
run (recorded-not-gated when it is).

### §9.8 SOUNDNESS HOLE caught by the differential — Fix B moved to the settle

The §9.7 implementation put Fix B's union read AT THE DESTRUCTOR (seduced by
the P0's floor ≈ ceiling). The rewritten unit fixture then failed its on-arm
with `[LSet 1, LTop clsDestr]` — the rebuild's destructor had read a PARTIAL
union (the sibling construction had not translated yet). The failure itself
was order-luck, but its mirror image is not: had a construction site
translated AFTER a recovery that stamped `LSet` from the partial union, the
stamped set would EXCLUDE the true inhabitant — a false singleton feeding
devirt, the arrowSolverRoots miscompile class. **AR-D2's union-widening
argument requires the COMPLETE union; the translation-time read violates the
plan's own AR.** The corpus battery (E2E green both arms) did not catch it —
green suites are not a soundness proof for a latent dispatch window, exactly
the arrowSolverRoots lesson repeated.

**Repair (implemented):** Fix B is now `Monomorphize.settleCtorRows` — a
single order-free sweep between drain and graph assembly, where every
construction has contributed and union-widening genuinely holds. Fix A (the
per-value projection enrich) stays at the destructor. What this gives up,
recorded honestly: the translation-time propagation of recovered sets into
USES (the destructor-bound `f` and its apply sites) — feeding the aggregate
union into a specific value's use REQUIRES a non-committal lower-bound form
(Part C's `LPartial`) or a devirt-declining member class; both are recorded
follow-ups, neither is built. The settle heals the ctor REGISTRY rows
(census, coverage, graph consumers) soundly.

**Lesson (goes with L2/L8a):** a unit differential is not redundant with a
green E2E battery — it explores orderings the corpus happens not to take.
The fixture found in one run what 1,717 E2E tests missed.

**Sound-design battery (final):** corpus A/B numbers IDENTICAL to §9.7's —
top 2,133→1,457 (−676), `Eerr` k1 1515→2028 / top 264→2, `Cerr` k1
1196→1724 / top 264→4, `map` top 307→193, clsDestr|ctor 545→23,
clsDestr|elm 387→233, conflict UNCHANGED, var untouched, coverage
88.99→89.61 %, wall +2.4 %. The identity of the deltas shows the registry
outcomes never depended on the unsound early stamps — the elm-row heals
came from Fix A alone, and the ctor rows heal equally from the settle.
VALIDATE leg clean; E2E 1,717/1,717 BOTH arms; **elm-tests 13,390 / 12 —
the differential now PASSES** at the known baseline.

**FLIPPED DEFAULT-ON 2026-08-31 (user decision).** Post-flip defaults E2E
1,717/1,717; elm-tests 13,390/12 (known baseline, differential included) —
no overlapping-flag pin broke this time. Shipped-default coverage is now
89.61 %; the remaining ⊤ book: poison 570, decl residue (clsDestr elm/cycle
303 + clsLet 174 + clsMisc/clsLocal 46), abi 216, conflict 112. ### §9.9 Dispatch A/B (Run-AO rail, 2026-08-31) — EXACTLY NEUTRAL

Protocol: counters applied at LOWERING
(`ECO_LSS_DISPATCH_SITE_COUNTERS=1`) to the two self-compile artifacts from
§9.7's battery; each resulting compiler then runs the SAME cold workload
(self-compile of `Terminal/Main.elm`) under `ECO_DISPATCH_STATS=1` with
SHIPPING-DEFAULT env — the arms differ in how each compiler was BUILT, not
in what it does at run time.

| | off-built | on-built | Δ |
|---|---|---|---|
| **sat** (the headline) | 2,290,875,173 | 2,290,875,104 | **−69 (−0.000003 %)** |
| gen | 2,254,164,532 | 2,254,164,468 | −64 |
| typed | 36,710,641 | 36,710,636 | −5 |
| fast | 633,840,372 | 633,840,365 | −7 |
| **distinct sites** | 7,322 | **7,293** | **−29** |
| RSS | 10.06 GB | 10.04 GB | −0.16 % |

**Verdict: exactly neutral**, joining `refIdentity`/`refPapSpine`/`injTotal`.
`destrAnno` buys analysis completeness (⊤ −32 %, k1 +1,129) at zero dispatch
cost AND zero dispatch benefit.

**The one real signal is `distinct`:** 29 fewer distinct closure-evaluator
sites participate in dynamic dispatch, for only ~69 events — i.e. the devirt
DID fire, on sites averaging ~2 events per run. That is exactly what the
heal profile predicts: the mass is `Eerr`/`Cerr` (528 of 1,052 ctor
positions), the PARSER'S ERROR constructors, which are cold by construction
in a successful compile. Precision landed where the program does not spend
time.

**Protocol check passed:** the two runs' workload outputs are BYTE-IDENTICAL,
confirming both arms performed identical analysis at run time (the flag is
default-on for both since the flip) — the comparison isolates build-time
effects, as the rail requires.

**Wall inconclusive here** (7:54.7 on vs 8:01.0 off = −1.3 %), and it
contradicts the clean §9.7 measurement (+2.4 %); both sit inside the
recorded ±2.3 % noise floor, and these runs carry dispatch instrumentation.
Treat §9.7's +2.4 % as the estimate and neither as a finding.

**What this means for the arc's direction.** Three consecutive precision
mechanisms have now measured dispatch-neutral. The gap is not analysis
completeness any more — it is that **nothing consumes multi-member or
newly-completed sets**: GAP-6 (no sum lowering; multi-member sets have no
dispatch consumer) is the binding constraint, and the healed positions are
cold besides. A future precision mechanism should be justified by a NAMED
hot consumer, or by the exploitation work (LPartial / use-site feeding /
sum lowering), not by coverage.

**The liveness census quantifies WHY (2026-08-31 read of the same run).**
`liveness: attempts=512,565 hit=512,565 hitBp=10000` — the positive control
passes, so the hook names 100 % of the applications it sees and the split
below is a real property (the naive control's premise "concrete BECAUSE
called" was refuted Aug 27; a low `controlBp` is the correct reading of a
working instrument, not an artefact).

| population | arrows | applied | rate |
|---|---:|---:|---:|
| **var** | 17,532 | 7,485 | **42.7 %** |
| **set (covered)** | 24,425 | 2,515 | **10.3 %** |

**Var arrows are applied at 4× the rate of covered ones.** Against the Aug-27
baseline (var 8,248/20,815; set 1,601/14,405 — cross-BUILD, so indicative
only): the arc added ~10,020 set arrows and only ~914 of them are ever
applied — **~9 % of newly-resolved arrows sit on called paths**. That is the
quantitative statement behind three consecutive dispatch-neutral results:
precision has been landing preferentially on arrows the program never calls.
It also bounds the remaining opportunity — ≥7,485 var arrows ARE live call
sites with no nameable target (genuine incompleteness, the honest numerator),
while 7,645 of 17,645 applied arrows (43.3 %) are in NEITHER bucket
(applied but never zonked) and remain unattributed.

## §11 THE HOT-CONSUMER MAP (2026-08-31) — task A of the live-var dig, and
## it redirects the arc

Symbolized all 7,293 dispatch-stats rows (fp rebased via the printed
`eco_alloc_closure` anchor against `nm eco-disp-on`; rows key by TARGET
evaluator) and mapped anonymous lambdas to their producing function via the
MLIR's `papCreate` nesting (12,775 lambda→producer edges).

**Generic dispatch by producer family (of 2.29 B sat events):**

| family | events | share |
|---|---:|---:|
| `System.TypeCheck.IO.andThen` (returned k-closures) | 483.8 M | 21.1 % |
| unattributed nested lambdas (mostly the same family's continuations) | 550.5 M | 24.0 % |
| `Data.IORef.readPointCell` (ONE lambda: 14939) | 228.9 M | 10.0 % |
| `System.TypeCheck.IO.map` | 180.6 M | 7.9 % |
| `newPointCell`/`writePointCell`/`traverseList` | 121.4 M | 5.3 % |
| `Compiler.Type.Unify` monad (andThen/pure/merge/…) | ≈117 M | 5.1 % |
| `UnionFind.fresh` | 43.8 M | 1.9 % |

**≈44 % of ALL generic dispatch is the compiler's own `System.TypeCheck.IO`
state monad** (likely well over 50 % counting the unattributed
continuations), plus ~5 % the Unify monad. The whole effectful compiler
funnels through one bind chain.

**The refutation:** the census readings at these producers are NOT var —
`readPointCell|/r` = **k1** (the 228.9 M-event target is a KNOWN SINGLETON),
`andThen` head/callback k1, `andThen|/r` = **kN 2,030 rows vs k1 1,094**.
The analysis already knows these sets. The dispatch persists because
(1) each hot `andThen` spec's io/k positions aggregate MANY step-closures →
honest kN → **GAP-6: multi-member sets have no dispatch consumer**; and
(2) where a producer's row IS k1 (`readPointCell|/r`), the knowledge does
not reach the generic apply site inside the shared `andThen` spec as a
singleton — the site's own slot unions everything piped through it.

**Verdict on the B/C/D chain (the user's "provided they continue to make
sense" gate): they do not.** B/C asked "which live vars would pay if
transported" — but transporting them lands in kN at shared monadic specs,
which nothing consumes; the demand side is answered without them. D's
never-zonked bucket is measurement debt, not opportunity, under the same
constraint. All three closed unrun, with this section as the reason.

**What WOULD pay, in order of expected leverage:**
1. **Bind-inlining / monad-inlining of `System.TypeCheck.IO`** — the classic
   fix: inline `andThen` so each continuation is statically known at its
   apply site; ~1 B events in scope. (MonoInlineSimplify exists; andThen may
   be blacklisted or too large — sizing needed.)
2. **Sum lowering for small kN** (GAP-6 proper): dispatch a member-switch
   for 2-3-member sets at hot sites — the paper's §5.2 `match`, gated by the
   M5 NO-GO's census being re-examined at TODAY's set quality.
3. **`readPointCell`-class singleton devirt through shared specs**: the k1
   exists at the producer; a per-call-site split (keying or inlining of the
   one-line accessor) recovers it.

### §11.1 LEVER 1 SIZED (2026-08-31): bind-inlining does NOT reach the
### hot rows — in either of its existing mechanized forms

**Form A — inliner whitelist (`inline.whitelist` / cost bypass): structurally
dead, no measurement spent.** The HOF-elimination arc already dug this hole
(memory `eco-hof-elimination-plan.md`, H6.0/H6.2 Jul 2026): `andThen f ma`'s
mono body is ONE `papCreate` (the arity-3 continuation lambda capturing
`f`,`ma`); every reference in today's artifact is a *direct static
`eco.call`* of the arity-2 spec (431 call lines over 334 surviving specs —
none of the dispatch is at these sites). Inlining the mint moves an
allocation into the caller; the dispatch lives in the generic applications
`ma s0` / `f a s1` of CAPTURED values inside the continuation, which
substitution cannot reach — H6.0's "stored-continuation class, NOT
inliner-reachable". Today's `ECO_INLINE_REPORT` confirms the population is
still escape-dominated: `fnres-specs=1,473`, applied 663 vs
returned+arg+let 1,462.

**Form B — U2b arity raising (`ECO_ARITY_RAISE=1`, ARM=0 ceiling), the
mechanism built FOR this shape (sound since Jul 16, parked on wall):
measured on the Run-AO dispatch rail, and it MISSES the target.**
Raised build: `raised=1,164`, staged population 1,473→311, partialMerges
+1,370, closuresRemaining −6.2 %. Correctness: the raised compiler's output
is BYTE-IDENTICAL to the same-source defaults output (`930ecb…` both; the
first md5 check against Aug-28 `don-out.mlir` differed only because the
source moved — always regenerate the control on today's source).

| counter | defaults arm | raised arm | delta |
|---|---:|---:|---:|
| sat (generic) | 2,290,875,104 | 2,597,608,906 | **+306.7 M (+13.4 %)** |
| fast (LSS devirt) | 633,840,365 | **0** | −633.8 M |
| typed | 36,710,636 | 34,598,787 | −2.1 M |
| sat+fast total | 2,924.7 M | 2,597.6 M | **−327.1 M (−11.2 %)** |
| wall | 7:54.73 | 8:01.23 | +1.4 % (≤ noise) |

Three findings:
1. **The hot IO-monad rows are EVENT-IDENTICAL across arms** — top site
   228,876,195 (the `readPointCell` lambda) and #2 93,578,155 to the digit.
   Raising collapses only `fnres-applied` sites; the bind chain's
   applications are of *captured* continuations at escaping sites, which
   raising converts to PAPs but still applies generically. The −327 M net
   came from elsewhere (the applied minority + merge fixpoint).
2. **Raising ZEROES the LSS fast path** (fast 634 M→0, distinct sites
   −449): raised closures clear `srcLambda`/`closureKind`/`captureAbi` by
   design (LSS_009 — must not impersonate the source member), so every
   devirt/fast site degrades to slow generic. Any raise-based lever must
   first teach LSS to mint members for raised workers, or it fights the
   whole LSS arc.
3. **July's +55 % wall did not reproduce** on today's rail (+1.4 %, inside
   the ±2.3 % floor) — that number came from a different-scale protocol.
   Wall is NOT the blocker anymore; *reach* is.

**Verdict: lever 1 CLOSED as mechanized.** Neither substitution (form A)
nor arity raising (form B) reaches the captured-continuation applications
that carry the ≈1.26 B IO/Unify-monad events. What can reach them:
(a) **lever 2, sum lowering** — the consumer-side fix needs no producer
restructuring at all (the sets at those sites are honest kN); (b) a
capture-aware collapse (defunctionalization — the paper's own escape);
(c) restructuring `System.TypeCheck.IO` itself (hand-eta `andThen`/`pure`/
`apply` the way `map`/`foldrM` already are — changes the member from an
anonymous mint to `p|andThen|2` but does not shrink the set; only worth
bundling with (a)).

**Follow-up recorded (user question, 2026-08-31): could raising KEEP or
FORWARD member identity instead of clearing it?** Yes, mechanically — and
it would convert form B from "fights LSS" to "composes with LSS":
clearing exists because the OLD member (the continuation mint lambda)
describes a value with a different ABI than the raised shape, and a
stampable stale member is the papMembers miscompile class (devirt drops
captured args). But the raise transform is 1:1 and deterministic: the
value that was "the closure `andThen`'s body mints" IS, post-raise, "a
PAP of raised-`andThen` with 2 of 3 args supplied" — which is EXACTLY
what a `p|<global>|<supplied>` member already describes, ABI included
(papMembers models the uniform PAP splice). So a sound forwarding pass
is: for each raised spec X (old arity k), rewrite every stamped set
replacing X's mint-lambda member with `p|X|k` (layout-qualified per
LSS_024), and stamp the PAP values that `annotateCallStaging` re-derives
at old-arity call sites with the same member. Raising runs post-mono
(after LSS), so this is a GlobalOpt-side annotation rewrite, not an
engine change. Expected effect: restores the 634 M fast events while
keeping the −327 M net, i.e. form B would become the first strictly-
positive dispatch composition of the arc. PARKED as exploitation — the
arc's present focus is COVERAGE over var (see §12), and this only pays
at exploitation time.

**Re-centering (user directive, 2026-08-31): the arc returns to raising
LSS coverage over `var` — understanding why each var position is never
written and how it can carry an ACCURATE set.** Sum lowering and the
raise-forwarding above are deferred exploitation. The §11 B/C/D closure
was evaluated against *dispatch* payoff; under the coverage framing the
var questions reopen — as §12.

## §12 THE VAR DIG (2026-08-31, in progress) — why 13,389 positions are
## never written, and how they can carry accurate sets

Offline attribution from the shipped-default census log (`dab-on.log`,
142,904 pos rows), before any new instrument:

**Structure (path classes):**
- **c-path var = 7,636 (57.0 %)** — ctor payload chains; the §1 Decoder-
  family territory, deep rungs (`/c1/r^n` to depth 10; 5,418 at depth ≥ 6).
- **pure argument-spine `/aN/r+` = 3,281 (24.5 %)** — successors of heads:
  if `/a0` holds `{g|X}` then `/a0/r` is `{p|X|1}` by construction (the
  Aug-28 finding). Together: **81.5 % of ALL var in two structural classes.**

**Knowability (mirror over (global,path) cells):** 8,531 var (63.7 %) sit
in MIXED cells where sibling specs of the same (global,path) DO hold a set
(e.g. `foldl|/a0/r`: 162 var vs 2,894 set — 95 % of siblings know);
4,858 (36.3 %) in 809 pure-var cells (dominated by the deep Decoder rungs).
Mirror = the channel CAN carry, NOT that the sibling's set is this spec's
answer (sibling-copy is unsound — Aug 28).

**Parent-cell coverage (cell-granularity approximation):** parent fully
known 12.6 % / parent fully var 26.4 % (chain interiors — fixing roots may
cascade) / MIXED 56.6 % — unresolvable at cell granularity.

**Identity concentration:** 13,389 instances = 7,895 distinct never-written
`entry.vn` (1.70 positions per missing write) across 2,957 entries.

**Instrument shipped:** pos rows now carry the registry spec index as a
5th field on EVERY row (previously var-only), making per-INSTANCE
parent/child pairing decidable from one census log — "is the head KNOWN
in the same spec whose `/r` is var?" is the exact candidate count for a
sound spine-successor mechanism.

### §12.1 Per-instance parent pairing (varpos.sh, 2026-08-31)

Coverage line on today's source: positions=141,044 k1=95,563 kN=30,903
var=13,389 top=1,189 (89.66 %; ⊤ keeps drifting down with source).

| parent (same spec instance) | var count | share |
|---|---:|---:|
| **k1** — sound successor-injection candidates | 2,769 | 20.7 % |
| kN | 115 | 0.9 % |
| **var** — chain interior | 9,332 | 69.7 % |
| top | 114 | 0.9 % |
| non-arrow hop (ctor/record/tuple between arrows) | 971 | 7.3 % |
| root (no parent path) | 88 | 0.7 % |

Chain interiors DOMINATE (69.7 %) — the var pool is mostly ~1.7-deep
chains hanging from ≈4,057 roots. Chain roots by global: andThen 771,
map 450, foldl 282, apply 204, map3 197, Decoder 165, Ok 152 … (top-14 =
72 % of roots — same monadic/applicative family as everything else in
this arc). Restricted to c-paths: 6,610 of 7,636 c-path vars are chain
interiors and only 165 have a known parent — the Decoder family's payload
arrows hang from combinator-spec rows, so **c-path var is downstream of
the same roots, not an independent class.**

Reading: write the ≈2,884 root positions (2,769 parent-k1 + 115
parent-kN) and, if the store transports through the chains (refPapSpine
precedent), up to 9,332 interiors follow. The mechanism's soundness
question is within-vs-beyond declared arity at each parent member —
measured next (varpos2.sh: k1 rows now NAME their singleton member,
`k1:g;X` / `k1:p;X;k`, so the split is offline-computable).

### §12.2 FULL chain-root attribution — every var assigned a cause class
### (varpos2.sh, 2026-08-31)

k1 rows now name their singleton; climbing each var chain to its root and
attributing the WHOLE chain mass to the root's (member-kind × hop) class:

| chain-root class | var mass | share | mechanism |
|---|---:|---:|---|
| inside DATA — 97 % ctor-payload (5,956; tuple 121 / record 56 / list 30) | 6,163 | 46.0 % | **M-C** construction-site payload flow (this plan's L-chain) |
| `k1:p → /r` PAP-successor | 2,426 | 18.1 % | **M-A** successor write `{p\|X\|k}→{p\|X\|k+1}` — mechanical |
| `k1:l → /r` known-LAMBDA result | 1,412 | 10.5 % | **M-B** lambda-result transport (k1-gated, unlike argFeedback) |
| rooted at ⊤ | 1,142 | 8.5 % | blocked behind the ⊤ book (poison/abi/decl) |
| `k1:g → /aN` argument of known global | 861 | 6.4 % | **M-D** argFeedback channel, now gateable to k1-parent cells |
| `k1:c → /aN` ctor-argument arrow | 634 | 4.7 % | M-C adjacent (construction flow) |
| `k1:g → /r` global result | 383 | 2.9 % | M-A (within arity) / sig route beyond |
| registry-row root / kN-rooted / misc | 368 | 2.7 % | — |

Top parent members of the M-A class are curried CTOR/record-alias PAPs
and multi-arg globals (`p|Dict.insert|1→/r` 65, `p|TTuple|1→/r` 37, the
Config record family 22×5, `p|Eerr|2→/a0` …) — overwhelmingly WITHIN
declared arity, i.e. the successor member exists by construction.

**The answer to "why is var never written":** three writes are missing —
(1) nothing writes the PAP-successor member at `/r` of a known
partial-application spine (M-A; refPapSpine did exactly this for
reference spines — this is its completion to all positions); (2) nothing
transports a KNOWN lambda's own result set from its body to positions
that hold the lambda (M-B); (3) nothing carries a construction site's
arrow sets into ctor payload positions read elsewhere (M-C — the reason
this plan exists; `settleCtorRows` now does the ⊤ analog at ctor ROWS,
but var slots need a STORE write, not an annotation join, to avoid the
L7 `unionAnno(LSet,LVar)=⊤` tax). Chain interiors (69.7 % of the pool)
are expected to follow their roots through store unification (refPapSpine
precedent) — every mechanism's realized yield multiplies through the
chains and must be measured, not assumed.

**Proposed order (size × tractability):** M-A first (mechanical, sound,
precedent, ~2,800 direct + cascade), M-B second (1,412 + cascade), M-C
redesigned third (biggest at ~6,800 but needs the construction-flow
design), M-D last (reverted machinery, needs the k1 gate to avoid the
churn that killed argFeedback). Success metric per L1: k1/kN at the
named chain-root cells (`andThen` 771, `map` 450, `foldl` 282 roots…),
never bare coverage.

**Working hypotheses to falsify (in order):**
1. The `/aN/r+` class is spine-deepening residue: the papInject/refPapSpine
   successor machinery covers reference spines but not demand-side argument
   spines to full depth (deepDone=786 was L2's count; the residue was ~600
   sites in Aug-28's estimate, now measurable per instance).
2. The c-path class needs the ctor payload transport chain (§0's
   L-in/L-mirror/L-across/L-out); `settleCtorRows` (Fix B) now heals ⊤ at
   ctor rows — the analogous var question is whether the sibling-spec
   demand union can be fed to var rows too (union-over-specs is
   widening-only = sound; but LVar-vs-union needs care: unionAnno(LSet,
   LVar)=⊤ — the L7 tax — so the write must be a STORE write to the flex
   slot, not an annotation join).
3. Chain interiors (26.4 %) resolve for free once roots are written
   (unification transports through the store — refPapSpine precedent).

## §10 CONSOLIDATED LEARNING (2026-08-30) — what this arc actually established

Recorded because most of it corrects something this plan or its predecessor
asserted. In rough order of how much it should change future decisions:

**L1 — The coverage gate cannot distinguish a win from churn, and rewarded
churn.** `(k1+kN)/positions` counts a 5-member set exactly like a singleton.
`argFeedback` scored +0.40 pp while k1 FELL 82: var was converted into
multi-member sets, which devirt cannot spend. Any future mechanism must quote
**k1 at named positions** alongside coverage, or it can pass the gate while
making the compiler no better. This is the single most important lesson here.

**L2 — Probes must be derived from the data, and they falsify.** Three of this
arc's mechanisms were designed from a plausible reading of census aggregates
and were WRONG: `LssGapDecoderChain` (built from §1's reading) came back 100 %
covered; AR-v2-1/-2 called two mechanisms phantoms that the probes then proved
real; the `declZonk`/`lssFastOk` attribution was wrong by one function. In
every case a cheap probe or a finer census cell settled in minutes what
argument could not settle at all. Build the instrument before the mechanism.

**L3 — Attribution beats aggregation.** The ⊤-kind census (§4.9/§4.10) and
then its `decl` sub-split (§9) took "58 % of ⊤ is a placeholder class" to
"one line, `Store.elm:3611`, and one source pattern". Every step of that
narrowing was a few lines of census and one compile. The same technique
sized the arg-form population (`argdeep`) and proved the mirror hypothesis
(`var@<entry>.<vn>`: 1.69 positions per missing write).

**L4 — Per-spec splits prove knowability.** When the SAME (global, path) reads
k1 in some specs and ⊤/var in others (`Cerr|/r/r/a0`: 172 k1 vs 132 ⊤), the
position is not intrinsically unknowable — some path loses information that
another path keeps. That is the strongest available signal that a repair
exists. Conversely 35.4 % of var is never known in ANY spec (§8.0 P0.d) and no
transport can reach it.

**L5 — LSS_006 (fresh arrow structure per load) is the recurring root.** Both
this arc's mechanisms failed or half-failed on it: an argument's own
translated slots are not the callee's parameter slots; a lambda's type is
computed before its body exists; a `case`'s classified type shares nothing
with the branches that were just connected to it. Anything that "should
obviously already work" across two loads of the same canonical type almost
certainly does not.

**L6 — ⊤ is terminal, so prevention ≠ payoff.** Converting ⊤→var moves a
position from one uncovered class to another. It only pays if a write then
lands. Measure the *destination* (§9.2), not the departure.

**L7 — The lattice's ⊤-absorption is now a measured cost, not a theory.**
`argFeedback`'s +45 ⊤ were ALL `conflict` — `LSet ∪ LVar = ⊤` firing where one
call site learned something and another had not. Precision added
asymmetrically manufactures ⊤. This is the concrete argument for the deferred
`LPartial` work (provenance plan Part C): without it, every partial
improvement pays a ⊤ tax.

**L8a — Chase the untagged residue; that is where the answer is.** Each
attribution round here left a residue (1,225 → 1,012 → 0) and each time the
residue, not the attributed part, held the finding. A partial attribution that
"mostly explains" the mass is worth very little: the first round's 8 tagged
positions out of 1,233 would have supported any conclusion at all.

**L8 — Negative and reverted results are the deliverable.** `argFeedback` was
built, measured, reverted, and is recorded with its numbers; `argPoints` is
now measured-inert with the reason (signatures stay 84 % trivial because
demand-side enrichment never touches the signature channel). Both are more
useful than the +0.40 pp would have been.

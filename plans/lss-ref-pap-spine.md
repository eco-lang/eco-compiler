# Reference-spine PAP successors — `lss.refPapSpine`

**Status: COMPLETE + FLIPPED DEFAULT-ON 2026-08-28 (user decision, same-day
build-and-flip). Same-source coverage 79.85 %→83.10 % at EXACTLY neutral
dispatch. Escape hatch `ECO_MONO_LSS_REF_PAP_SPINE=0`.**
Date: 2026-08-28. Follows `memory/lss-remaining-unknowns-census.md` (the Aug 28
census that identified this as the one remaining lever with mass) and
`test/elm/src/LssGapReturnedClosure.elm` (the probe that isolated the shape).

---

## 0. The gap, measured

Self-compile census at current defaults: coverage 80.03 %; uncovered = var
16,821 (63.5 %) + ⊤ 9,677. The var population by position path:

| path | var rows | meaning |
|---|---:|---|
| `/a0/r` | 3,915 | value after applying the **argument** once |
| `/a0/r/r` | 833 | …twice |
| `/a0` | 771 | the argument itself (different gap) |
| all ending `/r` | 13,811 (82 %) | one-more-application values |
| …of those under `/a<n>` | **9,747 (58 % of ALL var)** | argument-spine PAPs |

The probe pins the mechanism: in `sumWith f xs = List.foldl f 0 xs` with
`sumWith (+) …`, position `/a0` reads `{k|Basics.add}` (covered — the head
injection works) but `/a0/r` reads **var**: nothing ever writes the arrow one
application deeper, even though its value is fully determined — applying a
known arity-2 function to one argument yields exactly the PAP `p|Basics.add|1`.

**Why the slot is never written.** The reference injection is head-only:
`Translate.standaloneArgMember` injects at depth `spineDepthForGlobal g` = 1
(`LssInfer.elm`), and the kernel arm `standaloneArgKernelMember` is pinned to
depth 1 deliberately. The registration stamp (`regIdentity`) covers only the
SELF global's spine. The producer-side injection (`papMembers`,
`injectPapMember`) fires only at syntactic partial applications (`(::) x`) —
not at plain references. A plain reference of a multi-arg global to an
argument position therefore carries a bare spine, and the callee's `/a0/r`
zonks to `LVar` (`causeFlex`, the never-written readback).

## 1. The change

**At every standalone-reference injection site, after the existing head
injection, also write the PAP successors down the loaded type's result spine:**

> for `d` in `1 .. declaredArityOf g − 1`: write member
> `Engine.memberIdFor (papMemberKey g d)` — the key `p|<global>|<d>` — into
> the arrow slot at spine depth `d`.

This is a **store write at the reference**, so ordinary unification transports
it everywhere the value flows — into the callee's parameter arrows (the
`/a0/r` demand positions), through let-bindings, into branch joins (store-level
member union, no `LSet ∪ LVar` cliff), and into the signature channel — with
no per-enqueue-site work at all.

The member ids are **the same ids** the two existing `p|` producers mint:

- `injectPapMember` (papMembers, default-on) at partial applications:
  `Engine.memberIdFor (papMemberKey global argCount)` — `Translate.elm:4075`.
- `memberIdForDepth d>0` (regIdentity, default-on) on the self spine:
  `Engine.memberIdFor (papMemberKey g d)` — `Translate.elm:4106`.

Same interning function, same key string ⇒ ids unify at every join by
construction (the E9.2 one-identity rule). `papMemberKey` (`Translate.elm:4084`)
documents exactly the needed semantics: *"`p|<global>|<supplied>`. Distinct per
(global, arity-prefix) because those ARE distinct values — and distinct from
the callee's own `g|`/`k|` key, which … licenses a direct-call rewrite that a
PAP cannot support."* A spine arrow at depth d IS the value with d args
supplied.

Scope v1: `VarGlobal` (plain and kernel-alias), `VarCycle`, `VarEnum`,
`VarBox` — every arm of `Translate.injectArgLambdaMember` (`:3890-3934`) and
its four LssInfer mint twins (`LssInfer.elm:1393-1411`), which the S.10
lockstep rule already requires to move together. `classifyRef` (bare
references, `Translate.elm:1787`) routes through `injectArgLambdaMember` and
is covered automatically. Lambda literals are OUT of scope (they already
spine-inject, differently — §3 AR-6).

Flag `lss.refPapSpine`, default **False**, env `ECO_MONO_LSS_REF_PAP_SPINE`,
hash token `lssRP=1` (artifact-affecting: annotations and keyed spec keys
move). Flip decision with the user after the battery.

## 2. Why not the alternatives

- **Flip the existing `spineArity` flag (S.10, dormant, default-off)?** It
  injects the SAME `g|X` member at every spine depth. That names two different
  runtime values (the bare global and its PAP) with one id — the exact
  split/conflated-identity shape the papMembers arc rejected: `g|` is
  stampable, and a stamped `g|X` singleton at a PAP position licenses a
  direct call that drops the supplied arguments; only consumer-side arity
  guards stand between that and the recorded miscompile. Worse, it now
  CONFLICTS with papMembers (default-on): the same PAP value reaches some
  positions as `p|X|1` (producer path) and would reach others as `g|X`
  (reference path) — a split identity that joins to 2-sets and kills the
  singleton consumers, the disease rootFold just cured for `l|`/`g|`.
- **Registration-time demand stamping (extend `stampSpineGo` to argument
  positions)?** Works only for sets that survive into demand types; misses
  let-bound flows, sig-channel transport, and store-level joins. Also needs
  the every-enqueue-site discipline that made regIdentity delicate
  (`seedSpec` bypass trap). The store write is upstream of all of that.
- **Zonk-readback derivation (child var + parent set ⇒ successor)?** Sound,
  but derived sets would not participate in further solving, and the zonk
  lacks the member→global/arity plumbing (`ZonkCtx` has no `toptNodes`).
  Strictly weaker than writing the store at the source.

## 3. Adversarial review

### 3.1 Against the paper (fidelity)

The paper's `𝒬` injects **every** λ's identity into its own arrow annotation —
including nested λs: `λx.λy.e : Int −{λx…}→ (Int −{λy.e}→ Int)`. The INNER
arrow carries the inner λ's singleton at the definition, and instantiation/
unification transport the whole annotated type wherever the value flows. So in
the paper, `foldl add`'s callback parameter receives `/a0/r = {λy.e}` from the
ARGUMENT'S OWN TYPE, via ordinary unification — no special machinery.

Eco compiles curried globals as flat multi-arg evaluators, so "the inner λ" as
a runtime value is the PAP object, and papMembers already established
`p|g|d` as its defunctionalized identity (with the explicit finding that
reusing `g|` is not a faithful identity — it licenses rewrites the PAP cannot
support). The reference-spine injection is therefore **𝒬 applied to the
nested λs of the conceptually-curried global at the point where its type is
instantiated**, with transport left to unification exactly as in the paper.
The technique differs (PAP ids for nested-λ ids; store writes for annotated
instantiation) but the resulting judgment is the paper's: a complete singleton
at the nested arrow position, naming the unique value that inhabits it.

The LSS_013 stop at `declaredArity` is also the paper's boundary: beyond the
last parameter arrow, the type's arrows belong to the RESULT of the body,
whose set the paper derives from the body — Eco's body writes/sig channel —
not from `𝒬` at the reference. (Probe evidence that this boundary is already
honored where the tie works: `adder`'s `/r` is covered by the body tie, and
must remain untouched by this change — battery pin §5.)

Verdict: **faithful**; strictly closer to the paper than head-only injection,
because the paper has no head-only notion at all — its `𝒬` is total over
nested λs.

### 3.2 Against the code (AR-1..AR-10, verified)

- **AR-1 — key parity: VERIFIED.** All three mints route through
  `Engine.memberIdFor (papMemberKey g d)` (`Translate.elm:4075, 4106`; this
  plan's new walk). Whatever layout qualification `memberIdFor` applies is
  uniform across them — parity by construction, no new interning path.
- **AR-2 — `p|` members cannot devirt-misfire.** `papMemberKey`'s contract:
  `p|` is "distinct from the callee's own `g|`/`k|` key, which … licenses a
  direct-call rewrite that a PAP cannot support." `AbiCloning.stampCall`
  requires a `MemberInfo` instance (`Dict.get m index`); `p|` ids are plain
  interned strings with no instance and no `insertMemberGlobal` registration,
  so the singleton path declines and `postSettleTarget` cannot resolve a spec.
  MUST be re-verified in the battery: dispatch counters exactly neutral.
- **AR-3 — `LSet ∪ LVar = ⊤` at budget-collided joins.** A widened-key spec
  joining a stamped demand with an unresolved one turns a var position into ⊤
  (coverage-neutral swap, encoding-worse). Bounded: the PARENT position's
  join degrades symmetrically in that scenario, so no new class of loss —
  but `top` may rise while `var` falls more. A/B reports both; GO/NO-GO in §5.
- **AR-4 — kernel-alias inner arrows: hazard does not apply.** The HEAD-ONLY
  pin exists because `kernelToSig` "misaligns at inner arrows (it takes the
  first n modes of the full sig against a residual param row)" — a hazard for
  **`k|` members** specifically (`LssInfer.elm:1385-1389`,
  `Translate.elm:3949`). The head stays `k|` (unchanged); the successors are
  `p|` ids, which `kernelToSig` never consults. The alias global's
  `declaredArityOf` is correct since the papMembers arc fixed the
  `declaredArityGo` kernel-alias arm (the `(::)`-floored-at-1 defect).
  Producer parity holds too: `injectPapMember` for `(::) x` keys by the ALIAS
  global, as does this walk.
- **AR-5 — `spineArity` overlap.** Both flags on would produce
  `{g|X, p|X|d}` 2-sets at inner arrows (soundness fine, singletons dead).
  Documented mutual exclusion in both flags' comments; no hard guard —
  `spineArity` is dormant and slated for retirement if this ships.
- **AR-6 — lambda literals already spine-inject the SAME `l|` member**
  (`injectLambdaMemberQualified (List.length params)` →
  `injectSpineMemberId arity (srcLambdaKey …)`, `Translate.elm:3890-3891`,
  `LssInfer.elm:157`) — LSS_013's original blessing. That conflates the
  lambda with its PAPs, but no producer mints a distinct id for lambda PAPs,
  so no split-identity arises. Out of scope; noted as the LESS
  paper-faithful precedent (the paper would name the inner λ).
- **AR-7 — no enqueue-site discipline needed.** Store writes at the reference
  are upstream of every demand producer (including `seedSpec` and LSS_010
  retranslations), which is precisely the trap regIdentity had to handle
  site-by-site. Structural advantage of this design; nothing to do.
- **AR-8 — false-singleton audit.** `{p|X|1}` at `/a0/r` claims completeness.
  Other inflows to the same slot (e.g. `if p then f x else h` unifying `h`'s
  arrow with `f x`'s result) go through `unifySlotWithSetC`'s members arm,
  which UNIONS — the honest 2-set `{p|X|1, g|h}` results, exactly as with any
  existing injection. The only false-complete hazard is an inflow path that
  injects nothing — the pre-existing injection-totality concern (papMembers
  invariant), not new to this change; the never-written inflow joins as flex
  and adopts, same as everywhere.
- **AR-9 — fan-out is unchanged by construction.** The successor set is a
  deterministic function of the head set within the same type, so keyed-mode
  key equivalence classes do not split: demands whose `/a0` differed already
  keyed apart. Verify in A/B: `specsMinted` ≈ unchanged.
- **AR-10 — cost.** Extra store writes ≈ (# references to arity≥2 globals at
  injection sites) × (arity−1), against slotsMinted 794k / set-writes 260k
  baseline. Expect small; measure wall + `set-writes:` in A/B.

## 4. Implementation lowering

### 4.1 `Config.elm` / `Builder/Eco/Config.elm`

- `refPapSpine : Bool` after `rootFold` in the LSS record; default `False`;
  decoder field `"refPapSpine"`; hash token `lssRP=` on `/=` default; doc
  comment citing this plan. Env `ECO_MONO_LSS_REF_PAP_SPINE` (`"1"`/`"0"`),
  `applyLssRefPapSpineOverride` in the Builder env chain.
- Amend `spineArity`'s doc: superseded-by note + mutual-exclusion warning.

### 4.2 `LssInfer.elm` — the walk (single definition, both sides use it)

- **Move** `papMemberKey` from `Translate.elm:4084` to `LssInfer` (exposed);
  Translate call sites (`:4075`, `:4106`) become `LssInfer.papMemberKey`.
  (Translate imports LssInfer; the reverse is impossible — this removes the
  duplication temptation.)
- New:

```elm
injectPapSuccessors : TOpt.Global -> IO.Variable -> Step ()
injectPapSuccessors g v0 s0 =
    if not (s0.env.lss.enabled && s0.env.lss.refPapSpine) then
        Ok ( (), s0 )
    else
        let arity = declaredArityOf g 8 s0 in
        if arity <= 1 then
            Ok ( (), Engine.bumpArgFlowCensus "refspine|arity1" s0 )
        else
            papSuccGo g 1 arity v0 s0

-- v is the arrow at depth d-1; step into its result; write p|g|d into the
-- result's own arrow slot; recurse. Alias arm chases without spending depth
-- (mirrors spineGoC). Non-arrow result ends the walk (counted).
papSuccGo : TOpt.Global -> Int -> Int -> IO.Variable -> Step ()
```

  `papSuccGo` structure mirrors `spineGoC` (`LssInfer.elm`): `UF.get`,
  `IO.FunL _ res _slotOfParent` → obtain `res`; on `res` being `FunL … slot`,
  `Engine.memberIdFor (papMemberKey g d)` then
  `Store.unifySlotWithSetC False [mid] slot` (via the ctx-threaded
  `foldSetWrites` idiom or `injectSpineMemberId 1 mid res` — the
  `injectPapMember` idiom, `Translate.elm:4073-4076`); bump
  `refspine|stamped`; recurse `d+1` on `res`. `Alias` chases free; anything
  else bumps `refspine|end` and stops. A `seen` set guards cycles
  (mirroring `spineGoC`).

### 4.3 Call sites (the S.10 lockstep pair)

- `Translate.injectArgLambdaMember` (`:3890-3934`): in the `VarGlobal`
  (both alias and plain), `VarEnum`, `VarBox`, `VarCycle` arms, sequence
  `LssInfer.injectPapSuccessors g canVar` after the existing head injection.
- `LssInfer` mint arms (`:1393`, `:1397`, `:1400`, `:1411`) and the kernel
  arm (`:1390`): same sequencing after `standaloneMemberWith`. The kernel
  arm's HEAD stays depth-1 `k|` (AR-4); successors apply to the alias global.

### 4.4 Tests

`compiler/tests/TestLogic/Monomorphize/LssRefPapSpineTest.elm`, all pins as
off-vs-on DIFFERENTIALS (the TestPipeline lesson), config
`{ defaultLss | enabled = True, keyed = True, refPapSpine = arm }`:

1. **DIFFERENTIAL:** `useIt : (Int -> Int -> Int) -> Int`, `useIt plus2` —
   `/a0/r` of `useIt`'s stored demand: off = `LVar`, on = `LSet [_]`.
2. **PRODUCER CONVERGENCE (integer-level):** `useIt2 : (Int -> Int) -> Int`,
   `useIt2 (plus2 1)` — the on-arm `/a0/r` member of test 1 equals the `/a0`
   member of `useIt2` (papMembers' producer injection): the two paths mint
   THE SAME id.
3. **LSS_013 BOUNDARY:** `mk : Int -> (Int -> Int)` (declaredArity 1,
   returns a function) — `/r` (beyond arity) is arm-identical: the successor
   walk must not claim the returned value.
4. **HEAD UNCHANGED:** test 1's `/a0` head annotation arm-identical
   (`{g|plus2}` both arms).
5. **NO NEW MULTI-SETS:** test 1 on-arm `/a0/r` is a SINGLETON.

### 4.5 E2E probe

`LssGapReturnedClosure` flag-on: `pos|foldl|/a0/r|var` and
`pos|sumWith|/a0/r|var` disappear (both are kernel-alias references —
`Basics.add` — so this also gates the alias arm); `CHECK` outputs unchanged.

## 5. Battery + GO/NO-GO

1. Build (`--target eco-compiler` after elm edits; never bare
   `cmake --build build`).
2. Micro gate: the probe (§4.5), flag-on via env. **GO/NO-GO #1**: the two
   var rows become covered.
3. **P0 self-compile census A/B** (the user's measure-first step): defaults
   vs defaults+`ECO_MONO_LSS_REF_PAP_SPINE=1`, `ECO_MONO_LSS_REPORT=1
   ECO_MONO_LSS_ARROW_CENSUS=1`, fresh `eco-stuff` per arm. Read: coverage,
   var, top, `pos|` path histogram, `refspine|*` counters, `specsMinted`,
   `set-writes`, wall. **GO/NO-GO #2**: var falls ≥ 1,000 positions
   (order-of-magnitude sanity vs the 3,915-row `/a0/r` population); `top`
   rise < 20 % of the var fall (AR-3 bound); `specsMinted` within noise
   (AR-9).
4. elm-tests incl. the new differential suite.
5. E2E both arms (`touch test/elm/src` first — harness cache env-blind).
6. Flag-off byte-identity: defaults self-compile artifact pre/post-change
   `cmp` (change is fully flag-gated).
7. Q shadow flag-on: `diverge=0`.
8. Dispatch neutrality (AR-2): one Run-AO-style pair only if the census
   shows coverage moving ≥ 2 pp; expectation EXACTLY neutral.
9. Record results here; **flip decision with the user**.

### 5.0 Battery results (2026-08-28)

- **elm-tests: 13,382 passed / 12 failed — exactly the pre-existing dozen.**
  The new `LssRefPapSpineTest` (5 differential pins incl. the integer-level
  producer-convergence check) passes. One repair en route: `LssGroundingTest`'s
  flag-off pin ("one family id") broke — caused by the SAME-DAY `rootFold`
  default flip, NOT by this change (the fold interns one ground `g|` id per
  demanded layout; the suite inherits defaults and predates the flag). Pinned
  `rootFold = False` there — 5th occurrence of the overlapping-flag pattern.
- **E2E: 1,707/1,707 BOTH arms** (flag-on arm = flag-on-BUILT compiler
  compiling flag-on tests; `touch test/elm/src` per the env-blind-cache rule).
- **Q: Q-infer `diverge=0`, `REPRODUCES=yes` on BOTH arms** (the named gate).
  Q-shadow reads `REPRODUCES=NO` with sub-diverges on both arms — 70 flag-off
  (pre-existing; the shadow's recorded blindness to constraint generation),
  79 flag-on: +9 on +8,933 member constraints, proportional to volume, not a
  new class.
- Trap re-recorded: the flag-on `--target full` arm DELETES
  `bin/eco-compiler`; rebuild before any subsequent census run.

### 5.2 Dispatch neutrality (2026-08-28) — EXACT

Run-AO-style pair, both artifacts from current source (flag-off `out-qoff.mlir`
vs flag-on `out-refspine.mlir`), lowered and run on the same cold self-compile:

| | off-built | on-built | delta |
|---|---:|---:|---:|
| `sat` | 2,226,821,617 | 2,226,828,952 | +7,335 (3e-6 — registry-jitter band) |
| `typed` | 35,468,926 | 35,468,926 | **0 exact** |
| wall | 7:31.58 | 7:26.86 | noise |
| workload outputs | | | **BYTE-IDENTICAL** |

AR-2 confirmed: `p|` members decline devirt; +3.07 pp coverage moved ZERO
dispatch decisions. Also proves the flag-on-built compiler is a correct
compiler (byte-identical workload output).

### 5.1 P0 results (2026-08-28)

- **Micro gate PASS**: probe flag-on — `pos|foldl|/a0/r|var` and
  `pos|sumWith|/a0/r|var` GONE (var 2→0, coverage 72.22 %→83.33 %,
  `refspine|inject=4`, `arity1=2`); flag-off arm byte-identical to the
  pre-change artifact AND reproduces the pre-change census exactly.
- **Self-compile A/B PASS**: coverage **80.03 % → 83.10 % (+3.07 pp)**;
  var 16,821→13,026 (−3,795; 3.8× the gate); top 9,677→9,545 (**fell** — the
  AR-3 join risk did not materialize); k1 +4,593; kN +196; positions +862.
  `/a0/r` var 3,915→1,647 (−58 %); `/a0/r/r` 833→775 (deep spine covered
  where arity ≥ 3; the residual is arity-2 members whose depth-2 arrow
  belongs to the body — LSS_013, correctly not claimed).
  `refspine|inject=44,160`, `arity1=50,355`; set-writes flex +34k (the
  injections); wall 7:05 census-on (no regression).
- **AR-9 exceeded**: `List.foldl` created specs 2,540→2,137 — concrete `p|`
  key fragments replace per-type var numbering, MERGING demands that
  previously keyed apart. Fewer specs, not more.
- §5.6 correction: the "defaults self-compile artifact pre/post-change cmp"
  gate is INVALID as specified — the workload is the compiler's own source,
  which now contains this change, so the defaults artifact legitimately
  differs. The valid flag-off gate is the fixed-source probe byte-identity
  (PASSED) plus E2E flag-off.

## 6. Out of scope (recorded, not attempted)

- The 2,997 kernel-alias head-⊤ (LSS_004 poison overwriting the head stamp) —
  separate plan; different mechanism (poison exemption, not injection).
- Producer-side deep residue (`papInject|deep|d>1` — `injectPapMember` stops
  at the residual head; the same `papSuccGo` could finish the job later).
- Lambda-literal inner-arrow identity (AR-6) and ctor-payload positions
  (`/r/c1` var rows).
- Grounding/exploitation of the new `p|` singletons (completeness first).

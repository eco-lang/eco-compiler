# Item 2 — `inline.preserveSets`: a post-mono inliner with no set-clearing site

**Status:** IMPLEMENTATION-READY (2026-09-10). Not built.
**Parent:** `plans/pre-mono-lss-transforms.md` item 2. Evidence base:
`/work/pre-mono-transformation.md` §2, `scratchpad/q2-postmono-set-preserving.md`,
`plans/lss-inline-member-propagation.md` §2/§7.3/§8, and the `q2probe` fixture re-run for this
plan (§5). Every line number below was re-read from the current tree on 2026-09-10.

**Independence:** this item is on the POST-mono pass (`MonoInlineSimplify`). It does not depend
on items 0/1/3/4/5 and lands whether or not they do.

## 1. Problem

The user's target configuration is `preMono=1 postMono=1` — structural changes early, the
existing pass late — and the objection to it is that the post-mono inliner loses LSS sets.
MEASURED, the loss is one branch of one function:

| fact | value | source |
|---|---:|---|
| identity-clearing reshapes on the flag-off self-compile | **863** of 65,949 inlines (1.31 %) | reshape census, `bySite=tryInline:863` |
| same, `both on` (`preMono=1 postMono=1`) | 864 | isolated self-compile, report §2 |
| dispatch weight of the `returned` subset (176 of 863) | **0.245 %** of generic dispatch (2,165,299 / 883,435,458) | propagation plan §7.3, fixed-point binary, evaluator-attributed |
| the other 562 (`storedOrMulti`) | unstampable either way | propagation plan §7.1 |
| clearing sites that fire on real code | **one** — `tryInlineCall`'s strictly-partial branch | census `bySite` |

Everything else the pass does — exact and over-application inlining, both live `betaReduce`
arms, `ForwardClosure`/`ForwardPartialCall`, application merging, loopify, every DCE — preserves
member identity or consumes the closure outright (report §2 table). So "the post-mono pass loses
sets" is true of 1.31 % of what it does, and removing that 1.31 % removes the objection.

## 2. The clearing site, exactly

`compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`, `tryInlineCall` (`:4762`), arms in
source order:

| arm | line | what it does | LSS effect |
|---|---|---|---|
| budget / not a candidate | `:4765-4772` | `( Nothing, ctx )` | — |
| `exactOnly && numArgs < numParams` | `:4782-4787` | `( Nothing, ctx )` — hof-admitted candidates never inline partially | none (declines) |
| `numParams == 0 && numArgs > 0` | `:4789-4835` | value-typed body applied | preserves |
| **`numArgs < numParams` (strictly partial)** | **`:4837-4882`** | binds the available params, mints a residual `MonoClosure` with `srcLambda = Nothing`, **`lssMember = Nothing`** (`:4866`), `closureKind = Nothing`, `captureAbi = Nothing`, type from `residualClosureType` (`:3305-3316`, `topSynth` unless the peeled call type already matches), then `recordInline specId (bumpClearedMember … "tryInline" ctx3)` (`:4879-4881`) | **CLEARS + WIDENS** |
| `numArgs > numParams` | `:4883-4906` | over-application | preserves |
| exact | `:4908-4925` | exact | preserves |

Why it clears (propagation plan §2, and the comment at `betaReduce :3218-3227`): the residual
has a different parameter row and capture set from the source lambda. A set asserts ABI
interchangeability (`AbiCloning.joinGroup` admits an instance only under `sameSignatureLayout`
∧ `sameCaptureLayout`); reusing the id would normally be caught by that and by LSS_024's
fingerprint fence, but with the fence off a same-layout different-body reshape would be STAMPED
— a miscompile. Clearing is the correct answer for a residual that exists. This plan's answer is
that the residual need not exist.

The mirror branch, `betaReduce` (`:3169`) strictly-partial arm at `:3196-3239`, clears the same
way (`lssMember = Nothing` at `:3231`, `bumpClearedMember … "beta"` at `:3238`). It is reachable
from `rewriteExpr`'s `MonoCall region (MonoClosure …) args` arm (`:2765-2766`) — a lambda
LITERAL applied to fewer arguments than it has parameters — and from the let-forwarding path
(`:3884-3910`), where the exact arm (`:3885`) and the H6.2 first-stage-exact arm (`:3908`, which
passes `List.take nParams args`) never produce a partial. MEASURED: `bySite` on the self-compile
never lists `beta`; the `q2probe` shape (c) (`List.map (h 3) xs` with a local lambda `h`) does not
reach it in any arm. Dead on real code; guarded anyway, for symmetry and because it is one line.

## 3. Design

### 3.1 The guard

Add `preserveSets : Bool` to `RewriteCtx` (`:1405-1436`), initialised from
`inlineConfig.preserveSets` in `initRewriteCtx` (`:2387`, at `:2549-2550` next to
`kernelFactsDce = inlineConfig.kernelFactsDce` — that field is the exact pattern: a config Bool
read once into the ctx, consulted at the site).

At `:4837`, make the strictly-partial arm:

```elm
else if numArgs < numParams then
    if ctx.preserveSets then
        -- DECLINE. The residual closure this branch mints is the only
        -- identity-clearing reshape that fires on real code (P0 census:
        -- 863/863 at `tryInline`). Leaving the call alone leaves the callee's
        -- PAP in place, which LSS_040 fast-stamps as a `p|` member — the
        -- best-served member class in the compiler (2,041/2,418 sites).
        ( Nothing, bumpDeclinedPreserveSets ctx )
    else
        <existing body unchanged>
```

`( Nothing, ctx )` is precisely the value the `exactOnly` refusal at `:4787` returns; the caller
(`rewriteExpr`'s direct-call arm) then keeps the `MonoCall` as it was. Nothing else in the arm
changes; no other arm changes.

At `:3196`, the same two lines on `betaReduce`'s partial arm, returning the un-reduced closure
application exactly as the `numArgs == 0` arm does for its input:
`( MonoCall region (MonoClosure info closureBody _) args resultType Mono.defaultCallInfo, bumpDeclinedPreserveSets ctx )`
— but `betaReduce` does not receive the original call's `CallInfo`, so reconstruct with
`defaultCallInfo` (staging is recomputed by `annotateCallStaging`; `CallInfo` carries no set —
report §2). Since this arm is dead on real code its cost is nil either way.

### 3.2 Precedence

- **`partialHof` (`:2479-2483`).** Its whole purpose is to LIFT the `exactOnly` refusal so
  hof-admitted candidates reach the partial branch — i.e. to FORCE the clearing branch
  (`cleared` 863 → 1,900 with it on, report §2). With both on, `preserveSets` wins: the partial
  branch declines before it mints. Document at both flags and pin it (§6, T3). This is the
  intended semantics — `preserveSets` is the stronger claim.
- **`exactOnly`.** Unchanged; it declines before the arm is reached.
- **Whitelist.** Whitelisted candidates are admitted with `exactOnly = False` (`:2479-2483`,
  `not whitelisted`) and so inline partially today. **`preserveSets` declines them too.** The
  whitelist grants budget privileges, not identity privileges; a whitelisted partial inline
  mints the same identity-less residual as any other, and the flag's contract is "no clearing
  site fires", which admits no exception. The default whitelist is empty (`Config.elm:1069`), so
  this costs nothing at defaults; a user whitelist wanting partial inlines runs with
  `preserveSets=0`.

### 3.3 Census — the denominator

A `cleared=0` must be distinguishable from "the arm was never reached". Add to `InternalMetrics`
(`:1440-1470`) and the exported `Metrics` (`:70-100`):

```elm
, declinedPreserveSets : Int   -- partial inlines refused by inline.preserveSets (tryInline + beta)
```

bumped unconditionally at both guard sites (it is one Int; not gated on `report`). Render it on
the `inline-simplify:` line in `Builder/Generate.elm:renderInlineReportWith` (the field list at
`:926-950`), and keep the existing `inline reshapes … cleared= reshapesTotal= bySite=` line
(`:1015-1046`) as the gate: with the flag on it must read `cleared=0 reshapesTotal=0 bySite=`
AND `declinedPreserveSets=` must equal the flag-off `cleared` count on the same input. That
equality is the correctness check of the instrument itself.

### 3.4 Config plumbing

Exactly the `partialHof` chain:

| where | change |
|---|---|
| `Compiler/Eco/Config.elm:986` | `, preserveSets : Bool` in `InlineConfig`, with a doc comment naming this plan, the 863/1.31 %/0.245 % numbers, the precedence over `partialHof`, hash token `psets=`, env `ECO_INLINE_PRESERVE_SETS`, DEFAULT-OFF |
| `Compiler/Eco/Config.elm:1090` | `, preserveSets = False` in `default.inline` |
| `Compiler/Eco/Config.elm:1206` | `\|> D.apply (D.optionalField "preserveSets" D.bool default.inline.preserveSets)` |
| `Compiler/Eco/Config.elm:1444` | `, "psets=" ++ (if cfg.inline.preserveSets then "1" else "0")` in `hash` — artifact-affecting, so every arm is cache-disjoint |
| `Builder/Eco/Config.elm:1749` | `applyInlinePreserveSetsOverride : Maybe String -> EcoConfig -> EcoConfig`, a verbatim copy of `applyInlinePartialHofOverride` (`:1749-1768`) with the field name swapped — RECORD UPDATE through `let inline = cfg.inline in { cfg \| inline = { inline \| preserveSets = True } }`, never a literal |
| `Builder/Eco/Config.elm:357` | one more `Utils.envLookupEnv "ECO_INLINE_PRESERVE_SETS" \|> Task.map (applyInlinePreserveSetsOverride …)` link in the override chain, and a line in the module doc's env list (`:85-91`) |
| `LssInstanceQualTest`-style record literals | grep tests for `partialHof =` literals of `InlineConfig`; convert any to record UPDATE on `Config.default.inline` (the §12 test-fixture lesson) |

`InlineConfig` has 19 fields today; 20 is nowhere near the 32-slot GC scan cap. Do not put this in
`LssConfig`, which is AT the cap.

### 3.5 What is deliberately NOT changed

- `residualClosureType`, `createBindingsForInline`, `freshenLetBoundNames`, `remapLambdaIds` —
  untouched; the branch is skipped, not rewritten.
- `ForwardPartialCall` (`:3779-3826`, use at `:3918-3932`) and application merging (`:2799-2820`,
  `partialMerges`) — untouched. They are LSS-POSITIVE: a would-be `p|` PAP becomes a saturated
  direct call and no closure is built. They do not go through `tryInlineCall`'s partial arm.
- `arityRaise` — untouched, still default-off, still clears everything when on. `preserveSets`
  does not gate it; a user turning both on gets the raise. Say so in the flag doc.

## 4. Adversarial review

**R1 — Is a declined partial inline ever worse than the residual?** The residual is a fresh
closure with `topSynth` type and no member: it cannot be stamped at all (`storedOrMulti`, 562 of
863) or is stamped only if a later consumer re-derives a singleton (`returned`, 176, 0.245 %).
The PAP left in place is a `p|<global>|k` member, which LSS_040 stamps at 84 % of sites (the
probe in §5 shows exactly this: `papCreate @Q2Probe_add3` with `singleton_fast` at defaults). The
377 `p|` residual declines (`papAmbiguous` 201, `papShapeMiss` 88, `papChar` 4) are the only
population where the PAP is not stamped either — and there the residual would not have been
stamped either. **Resolution: no case is worse; 863 cases lose an inline whose LSS value was
bounded at 0.245 %.** What IS forgone is the inline's own non-LSS value (one fewer PAP
allocation and one fewer indirect call per residual) — §7 measures it.

**R2 — Does `preserveSets` forgo the `partialHof` win (−83.9 M dispatch, −9.14 %)?** Only if both
are on, and then by design (§3.2). At DEFAULTS `partialHof` is off, so the hof-admitted class
already declines at `:4782` before this arm; `preserveSets` at defaults removes ONLY the
863 legacy/under-threshold partials. The −83.9 M came from removing over-application re-entry
(−43.5 M of it), not from stamping (propagation plan §8) — a different mechanism, at sites this
flag never touches at defaults. **Resolution: nothing forgone at defaults; with both on, the user
has asked for two contradictory things and `preserveSets` is the one that keeps the sets.**

**R3 — Does declining change program semantics?** No: the call is left exactly as written. The
only observable difference is one fewer inline. `ECO_INLINE_THRESHOLD=0` already declines every
inline and the E2E suite is green under it (plan §13), so "fewer inlines" is a configuration the
codebase is proven under.

**R4 — Could the `betaReduce` guard change behaviour where the arm is reachable?** The arm is
reachable from `:2766` for a source-level partial application of a lambda literal. MEASURED
never on the self-compile or on the (c) probe shape, but a program CAN write `(\a b -> …) x` and
store it. With the guard, that expression is left as a `MonoCall` of a `MonoClosure` — the shape
the input already had — which every later phase handles (it is the shape before any inliner
runs). **Resolution: safe; and the `declinedPreserveSets` counter will show if it ever fires.**

**R5 — The whitelist decision (§3.2).** A user whitelisting a global expects it inlined. With
`preserveSets` on, exact and over-application inlines of it still happen; only its strictly-partial
uses are declined. **Resolution: keep the uniform rule; document it at the flag; the empty
default whitelist means no existing behaviour changes.**

**R6 — Interaction with the pre-mono inliner (`preMono=1`).** None at the code level. The
both-on measurement (cleared 864 vs 863) shows the pre-mono pass's inlines are not the sites that
later reshape; with `preserveSets` on, the both-on configuration's `cleared` reads 0. That is the
whole point.

**R7 — Byte-identity at defaults.** The flag is off by default and the guard is an `if` on a
ctx Bool; the hash token changes the config hash string only when the flag is on. **Gate: the
default `.mlir` must be byte-identical and the fixed point must hold** (a codegen path that is
skipped cannot move the output, but the plumbing edits touch `Config`'s `hash`, whose default
arm must produce the same string as before — `psets=0` is appended, so the hash string DOES
change at defaults, which changes cache keys but must not change emitted MLIR; `cmp` the
`.mlir`, not the cache).

## 5. Probe evidence (re-run for this plan, `eco-q1b`, `q2probe/src/Q2Probe.elm`)

Shape (a): `let g = add3 1 k in List.map g xs` — a partial of a small global escaping into a
HOF. `add3` costs more than the default budget, so it is only a candidate at a raised threshold.

| arm | `inlined` | `inline reshapes` | `papCreate @Q2Probe_add3` in MLIR | `_call_kind` histogram |
|---|---:|---|---:|---|
| defaults | 12 | `cleared=0 reshapesTotal=0` | **1** | `singleton_fast` 13, `direct_known_segmentation` 4, `segmentation_unknown` 1 |
| `ECO_INLINE_THRESHOLD=50` | 37 | **`cleared=2 reshapesTotal=2 bySite=tryInline:2 \| storedOrMulti=2`** | **0** | `singleton_fast` **2**, `direct_known_segmentation` 10, `segmentation_unknown` **11**, `generic_apply` 1 |

The thr=50 arm is the self-compile's dominant reshape bucket reproduced: two residuals, both
`storedOrMulti` (the argument to `List.map`), the `p|add3|2` PAP gone. The `_call_kind` shift is
NOT attributable to the two residuals alone — at thr=50 `List.map`/`foldr` are inlined too and
their specs' sites are counted whether live or dead (the liveness caveat, report §7) — so it is
recorded, not read as a stamp count.

**Flag-on expectation, to be verified as Step 4's gate** (the flag does not exist yet):
`ECO_INLINE_THRESHOLD=50 ECO_INLINE_PRESERVE_SETS=1` → `inlined=35`, `cleared=0
reshapesTotal=0 bySite=`, `declinedPreserveSets=2`, `papCreate @Q2Probe_add3` = 1, runtime output
identical (`a: [6,7,8]`, `b: 50`, `c: [10,13]`).

## 6. Lowered steps

| # | change | file(s) | gate |
|---|---|---|---|
| 1 | `preserveSets : Bool` on `InlineConfig`; default; decoder; `psets=` hash token; doc comment | `Compiler/Eco/Config.elm` `:986`, `:1090`, `:1206`, `:1444` | elm-tests compile; `hash Config.default` differs only by the appended `psets=0` |
| 2 | `applyInlinePreserveSetsOverride` + chain link + module-doc env line | `Builder/Eco/Config.elm` `:357`, `:1749`, `:85` | `ECO_INLINE_PRESERVE_SETS=1` reaches `inlineConfig.preserveSets` (report line shows it) |
| 3 | `preserveSets` on `RewriteCtx`, set in `initRewriteCtx`; `declinedPreserveSets` in `InternalMetrics`/`Metrics`; `bumpDeclinedPreserveSets`; render on the `inline-simplify:` line | `MonoInlineSimplify.elm` `:1405`, `:1440`, `:2549`, `:70`; `Builder/Generate.elm` `:926` | self-compile at defaults byte-identical; `declinedPreserveSets=0` at defaults |
| 4 | the guard at `:4837` (and `:3196`) | `MonoInlineSimplify.elm` | §5's flag-on expectation on `q2probe`, exactly |
| 5 | unit tests T1–T3 | `compiler/tests/TestLogic/GlobalOpt/MonoInlineSimplifyPreserveSetsTest.elm` | pass; whole suite at the 13,464 / 12 baseline |
| 6 | E2E, both inliner arms, flag ON; and the `ECO_INLINE_THRESHOLD=0` leg | — | 887/889 each |
| 7 | self-compile reshape census with the flag on | — | `cleared=0 reshapesTotal=0`, `declinedPreserveSets=863` (± the same-input drift: the flag-off count on the SAME binary and source, read in the same run pair) |
| 8 | protocol Run, two arms (`off`/`on`), recorded in `benchmarks/lss-opt.md` | — | §7 |
| 9 | default-on decision per §7.3 | `Config.elm:1090` | one more Run + fixed point if flipped |

Order matters only in that 1–3 must compile before 4; 5 can be written before 4 (it should fail
first).

## 7. Tests and measurement

### 7.1 Unit — `MonoInlineSimplifyPreserveSetsTest.elm`

Built on `Pipeline.runToMono` + `MonoInlineSimplify.optimize` with an `InlineConfig` made by
record UPDATE from `Config.default.inline` (never a literal), `threshold = 50` so `add3`
qualifies, and `report = True` so the reshape census collects.

| test | fixture | pins |
|---|---|---|
| T1 flag off | shape (a): `add3 a b c`, `partialShape k xs = List.map (add3 1 k) xs` | `clearedMembers` non-`RESHAPES|` total = 1, `bySite` has `tryInline`, `declinedPreserveSets = 0` — the arm fires; this is the denominator |
| T2 flag on | same | `clearedMembers` total = 0 AND `RESHAPES|tryInline` absent AND `declinedPreserveSets = 1`; `inlineCount` = T1's − 1; the exact-inline count unchanged |
| T3 precedence | shape: an hof-admitted candidate (cost between `threshold` and `hofThreshold`, with a called function param — the `andThen` shape) called 2-of-3, with `partialHof = True, preserveSets = True` | `declinedPreserveSets = 1`, `clearedMembers` total = 0 — `preserveSets` wins |
| T4 beta arm | shape (c): `let h = \a b -> a * b + k in List.map (h 3) xs` | `declinedPreserveSets = 0` in both arms (documents that the beta partial arm is not reached; if a future change makes it reachable this test says so) |

### 7.2 E2E

- Full suite, `ECO_INLINE_PRESERVE_SETS=1`, at defaults and at `preMono=1 postMono=0`: 887/889
  (the two residuals pre-existing). Also `preMono=1 postMono=1 preserveSets=1` — the configuration
  this item exists for.
- `ECO_INLINE_THRESHOLD=0` leg unchanged (no inlines → the arm is never reached).
- `q2probe` runtime output identical across arms (`a: [6,7,8]`, `b: 50`, `c: [10,13]`).

### 7.3 Measurement and the flip criterion

One `benchmarks/lss-opt.md` A/B Run, `off`/`on`, one cold run each, census off, no probe
(entry shape: tables first, ≤10 lines of prose). Record the reshape census from a separate
report-on pair. **Expected: FLAT** — the 863 residuals' stampable subset is 0.245 % of dispatch,
and the propagation plan's §8 fact 2 shows clearing does not reduce aggregate stamping today
(`dispatchUpgraded` rose with more clearing). What would REFUTE flat: `Minor GC cycles` moving
by more than a handful (863 fewer residual closures is not enough allocation to move it; if it
moves, something else changed) or a wall delta ≥ 3 %. A separate dispatch uprobe run is worth
one leg: the expected sign is a small INCREASE in generic dispatch (each declined residual is one
indirect call kept) bounded by 863 sites' traffic — report it as the price, not hide it.

**Flip to default-on when** all of: E2E 887/889 in the three configurations above; the Run is
FLAT by the 3 % bar; the dispatch uprobe shows the price is below the noise of the last three
Runs (AR/AS/AT moved by ±10 M between arms on identical inputs — that is the noise floor); and
the both-on self-compile reads `cleared=0`. The flip is what makes `preMono=1 postMono=1` the
default-safe configuration for the rest of the parent plan; if the price is measurable, keep it
off and let item 1's η-expansion (which removes the IO-monad partials at the source) reduce the
population first, then re-measure.

## 8. Risks

- **The flag hides, not fixes.** With it on, a residual is never minted; with it off, the
  clearing site is exactly as before. There is no path in which a residual keeps a member — that
  is §2 of the propagation plan and stays closed.
- **A future transform adding a new partial-rebuild site** would not be covered. The gate is the
  reshape census: `bySite` naming anything other than `tryInline`/`beta` is the alarm, and
  `declinedPreserveSets` counts only the two guarded sites.
- **User whitelists** lose partial inlines under the flag (§3.2 R5). Documented at the flag.
- **Test fixtures** that build `InlineConfig` literals break when the field is added — the
  standing `LssInstanceQualTest` lesson; grep before the first compile.

## 9. What not to do

- Do not "keep the member" on the residual — propagation plan §2: type-identical, ABI-different,
  and a miscompile with the fingerprint fence off.
- Do not gate `arityRaise` under this flag; it is a different, larger clearing that is already
  off and measured (+76.6 % dispatch).
- Do not try to make the guard "smart" (decline only when the residual would be stored, inline
  when returned) — the `returned` bucket is 0.245 % and the classification needs the use-shape
  walk the census does after the fact; a per-site predicate here would be the §5 mechanism the
  propagation plan closed.
- Do not read the `_call_kind` histogram of a threshold-50 probe as a stamp count; the raised
  threshold inlines `List.map`/`foldr` and leaves dead specs whose sites are static only.

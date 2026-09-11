# Pre-mono LSS transforms — 01: η-expand definitions and continuations to declared arity

**Status:** BUILT AND SHIPPED DEFAULT-OFF (2026-09-10). Item 1 of
`plans/pre-mono-lss-transforms.md`. `inline.etaExpand` /
`ECO_INLINE_ETA_EXPAND=1`, hash token `eta=`;
`compiler/src/Compiler/GlobalOpt/PreMono/EtaExpand.elm`, called from
`Builder/Generate.elm:runMonoOptPipeline`, in front of the pre-mono inliner. See **§9 Results** for what was
measured and what the gates said. The one blocker it exposed — a PRE-EXISTING
miscompile in E9.5's spec choice, `/work/combinator-uf-devirt-error.md` — was
root-caused with temporary per-stage tracing and FIXED the same day (LSS_025 amended);
§9.4 records both.
**Origin:** `/work/pre-mono-transformation.md` §3.1, §4.A; probes `SeqM`/`SeqEta`/`StateM`/`StateEta2`
(`scratchpad/q4probe/src/`). Depends on item 0 (`…-00-assign-mvar-ids-first.md`) for the
`TOpt.GlobalGraph MVarId` IR and `Compiler.GlobalOpt.PreMono.Fresh.mintNewNode`; runs after item 4
(`AliasForward`) so callee arities are the real targets'.

## 1. Problem

The heaviest class in the LSS ledger — the shared state monad `System.TypeCheck.IO`, MEASURED at
55.3 % of generic dispatch — fails for a purely SYNTACTIC reason. `andThen` and `map` are already
saturated in their definitions (`System/TypeCheck/IO.elm:239 map fn ma s0`, `:254 andThen f ma s0`),
but every caller writes the chain at the ALIAS arity:

```elm
prog : IO Int
prog = tick |> IO.andThen (\a -> …)          -- a CAF whose VALUE is a 2-of-3 PAP
```

`applyOneMore` (`LocalOpt/Typed/Expression.elm:123-131`) already merges `x |> f a` into
`Call f [a, x]`, so `prog`'s body is `Call andThen [k, tick]` — two of three arguments. The
continuation `\a -> …` returns another PAP. Inside `andThen`'s spec, `(f a) s1` therefore applies a
CALL RESULT, for which no member channel exists (report §4.0, last row). The decline census called
these sites "not reachable by LSS"; that was half right.

The handled shape is the same chain SATURATED — every `andThen` call has three arguments, `f` is a
lambda literal (mints `l|`), `ma` is a global (mints `g|`), one spec per `(f, ma)` demand, inside
which `ma s0` is `g2global`-direct and `f a s1` is a singleton. MEASURED on probes compiled with
`eco-i51` (`ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1`, `_call_kind` read from
`mlir-opt` text, LIVE sites only):

| probe | shape | live generic (EARLY) | note |
|---|---|---:|---|
| `SeqM` | `sequence : List (St a) -> St (List a)` at alias arity | 5 | 2 per `andThen` spec + 1 in `run` |
| `SeqEta` | same, η-expanded by hand | **1** | the residual is `ma s0` with `ma` ∈ {tick, tick2, pure 5} — a genuine 3-member set (GAP-6) |
| `StateEta2` | 3-deep chain, η-expanded | **0** | all `singleton_fast` |

Output `r: [30, 42, 54]` identical across arms. This plan makes the compiler perform that hand
rewrite. **Saturation, not inlining, is the mechanism**: the pre-mono inliner declined `andThen`
(`hofParam`) in the probe and the EARLY arm still reached 0.

## 2. Design

### 2.1 Declared arity, from alias STRUCTURE (Fact-2-immune)

```
spine : Can.Type MVarId -> List (Can.Type MVarId)      -- parameter types of the fully expanded arrow chain
spine (TLambda _ a b)                   = a :: spine b
spine (TAlias _ _ args (Filled t))      = spine t
spine (TAlias _ _ args (Holey t))       = spine (substTypeVars args t)      -- alias params are alias-local (plan 00 / §16 of the inliner plan)
spine _                                 = []
```

`Can.Type`/`TAlias`/`AliasType(Holey|Filled)` are `AST/Canonical.elm:307,377-379`. After item 0
the alias parameter ids in `args : List ( MVarId, Type MVarId )` are alias-local and the argument
types already carry ids, so substitution mints nothing. **The arity is read off the alias's
STRUCTURE** — `IO b = State -> ( State, b )` has arity 1 whether or not `b` is a variable — which is
why this survives the type-precision limit that caps the inliner (`determines`, 864 declined).

**VERIFIED at Step 1 (§2.7's open question):** `AssignMVarIds.rewriteCanType`'s
`TAlias` arm (`AssignMVarIds.elm:1392`) DOES descend into the alias body — through
`rewriteAliasType` (:1446), which walks both `Holey` and `Filled` — so arrow ids
are minted per annotation OCCURRENCE inside alias bodies and `substTypeVars`
mints nothing. The assumption held; see §2.7 for the part of it that did NOT.

`declaredArity d = List.length (spine (typeOf d))`, taking the DEFINITION NODE's meta
(`Define _ _ meta` / `TrackedDefine _ _ _ meta`, `AST/TypedOptimized.elm:462-463`; a Cycle
`Def _ _ _ tipe`'s `tipe`, `:361-363`). The inferred node type is always present and equals the
annotation after solving; the annotation (`AnnotationsByGlobal`, `:116`) is not consulted.
`syntacticArity` = params of a top-level `Function`/`TrackedFunction` body, else 0.
`deficit = declaredArity − syntacticArity`; the transform fires when `deficit > 0` and the body is
cheap (§2.5).

### 2.2 Definitions

For `Define e deps meta` (or `TrackedDefine r e deps meta`) with deficit `n` and spine
`τ₁ … τ_k` (k = declared arity), new parameters `x₁ … xₙ` take the LAST `n` spine types
`τ_{k−n+1} … τ_k` when the body is a `Function ps b` with |ps| = k−n, or the first `n` when the body
is not a function (then k−n = 0, so the two coincide). Result type `ρ` = the residual after the
full spine.

```
d = e            ⟹  Function Nothing [(x₁,τ₁)…(xₙ,τₙ)] (apply e [VarLocal x₁ … VarLocal xₙ] ρ) meta
d = \ps -> b     ⟹  Function Nothing (ps ++ [(xᵢ,τᵢ)]) (apply b [xᵢ…] ρ) meta
```

`TrackedDefine` builds a `TrackedFunction` with `A.At r xᵢ` params (`Reporting/Annotation.elm`
`At`/`toRegion :147`); `deps` unchanged (no new globals are referenced); the NODE's own `meta` unchanged, and the
Function's meta is that same type with its arrow slots CLEARED and re-minted (§2.7 — the body it
wraps stays underneath it, so reusing the value verbatim would put one `ArrowId` at two
occurrences). The Function's type IS the definition's alias-typed arrow, exactly the shape
`tick s = …` already has in the probes; a rebuilt EXISTING lambda keeps both its meta and its
`SrcLambdaId`. Fresh names `_eta<n>` from a per-pass counter: Elm identifiers cannot begin
with `_`, and the inliner's `_pi<n>` is a SUFFIX on source names, so capture is impossible without
scope tracking.

`apply e args ρ` builds the application and immediately normalises it (§2.4).

### 2.3 Continuation lambdas in argument position

For `Call r (VarGlobal g refMeta) args`, at each position `i` where `args[i]` is
`Function lid ps b` (or `TrackedFunction`): let `expected = spine (typeOf refMeta) !! i` (the
callee's parameter type at this site, aliases expanded — `andThen`'s first parameter `a -> IO b`
expands to `a -> State -> ( State, b )`, arity 2). If `arity expected > |ps|`, append parameters
`y₁ … y_m` with the trailing spine types and rebuild with body `apply b [y…] ρ'`. **The lambda's
own `SrcLambdaId` is KEPT** — it is the same source lambda with more parameters; no member exists
yet (Fact 1), and the id stays the future member key. This is the `\x -> …` ⟹ `\x s1 -> …` step in
`SeqEta`, and it is what turns the continuation into an `l|` member whose body is a SATURATED
direct call.

### 2.4 Normalising the new application — merge, push, beta

`apply e args ρ` is not `Call e args` blindly. The precedent is `applyOneMore`
(`Expression.elm:123-131`), which merges `a |> (f x)` into one call; this pass adds the arity check
that `|>` lowering does not need:

| shape of `e` | rule |
|---|---|
| `Call r (VarGlobal g m) as` with `declaredArity g ≥ |as| + |args|` | **merge**: `Call r (VarGlobal g m) (as ++ args) {tipe = ρ}` — this collapses `Call andThen [k, tick]` applied to `s0` into the 3-arg call; if `|as| + |args| > arity`, saturate to arity and wrap the remainder as an outer `Call` (mono handles over-application; LSS wants the exact call) |
| `Call r (VarKernel …) as` | merge likewise when the kernel reference's spine gives the arity; else outer `Call` |
| `Function lid ps b` (a lambda head) | **beta** via the inliner's Let-wrapping (`InlineSimplify.elm:1529-1545`: `Let (Def r p arg t) acc (metaOf acc)`, never substitution); remaining args as outer `Call` |
| `Let def body` | **push**: `Let def (apply body args ρ)` — args are `VarLocal _eta…`, no capture |
| `Case label root decider jumps` / `If` | **push into every branch**: `Inline e` choices in the decider AND every `jumps` entry (shared branch bodies) / each `If` branch and the final. Duplicating a VARIABLE reference is free; this is exactly how `sequence`'s `case actions of` became `SeqEta`'s two saturated branches |
| anything else | `Call r e args {tipe = ρ}` |

**`declaredArity g` is the callee's SYNTACTIC parameter count, read from the
graph — NOT the arrow count of its type.** This distinction is load-bearing and
was learned the hard way: an arrow chain counts the arrows of its RESULT too, so
at `b = s (k s) k` the instantiated type of `s bf uf x` has SIX arrows where the
definition writes three. Merging to the type's count built a six-argument call
to a three-parameter global and MISCOMPILED `test/elm/src/CombinatorTest.elm`
(`b square inc 4` printed 64, not 25). The implementation therefore builds a
`Callee { arity, cost }` index over the graph once, before rewriting — `Define`/
`TrackedDefine` bodies by parameter count, `Ctor` by its stated arity, Cycle
members keyed under their OWN `Global` (the graph holds a `Link` for each, and
the cycle node itself is keyed under the joined name) — and takes
`min arity (arrowCountOfTheSiteReferenceType)`, the cap being what keeps the
merge from outrunning the type it derives a result type from. A global with no
entry answers "unknown" and is not merged into.

**The arity must be the callee's POST-pass count, and getting there needs one
extra walk.** Reading the graph as it arrived under-merges exactly where it
hurts most: `sequence` is a Cycle member written at alias arity, so its
syntactic count is 1 while the expanded definition takes 2 — and the continuation
`\x -> sequence rest` then sees a SATURATED call to something expensive, is
refused by the cheapness gate, and the new state argument is applied
generically. The pass reintroduces, against its own output, the dispatch it
exists to remove. The unit suite's R8 fixture caught it as an unsaturated
branch (`[2,2,3,1]`).

So `run` computes the arity in two rounds. `arity0` is the syntactic counts;
`arity1 = buildPostArity arity0` gives each definition its DECLARED arity if the
pass will expand it (a walk that mirrors `expandDefinition`'s guards and builds
nothing) and its syntactic count otherwise; the rewrite uses `arity1` for BOTH
the cheapness gate and the merge. That is sound in the direction that matters:
`cheap` is monotone in the arity — a larger arity turns saturated calls into
PAPs, which only adds verdicts — so `arity0 ≤ arity1` means every definition
`arity1` predicts will expand really does. `arity1` can therefore only
UNDER-estimate the final arity, and an under-estimate costs an unmerged call
while an over-estimate is the `CombinatorTest` miscompile. One round and not a
fixed point, deliberately, for the same reason.

**Kernel merges are OUT in v1** (the `VarKernel` row above is not implemented).
A kernel has no graph node, so nothing pre-mono knows where its first stage ends,
and the same result-arrow over-count applies. An under-applied kernel call is
left as an outer `Call`.

After item 4 the callee is the forwarded target, so an alias wrapper's arity is
never read.

### 2.5 The cheapness gate

η-expansion moves the evaluation of everything LEFT of the new binders from once (CAF init or
closure creation) to once PER CALL. That is a win exactly when that work is nothing but building
the PAP/closure that the call would have applied anyway — the IO-monad P0 finding — and a loss for
`d = let big = expensive in \s -> …`. The gate, on the expression `e` that receives the new
arguments (applied recursively through the push rules):

```
cheap e = case e of
  Function/VarLocal/TrackedVarLocal/VarGlobal/VarKernel/VarEnum/VarBox/VarCycle/literal/Unit → True
  Call (VarGlobal g) as     → |as| < declaredArity g && all cheap as                          -- a PAP: builds, does no work
                              || (saturated && cost (body g) ≤ inline.threshold && all cheap as)
  Call (VarKernel k) as     → kernel cost class is `inline` or `gcLeaf` (KernelFacts by (home,name)) && all cheap as
  Let def body              → cheap (rhs def) && cheap body
  Case/If                   → cheap scrutinee/conds && all branches cheap
  Tuple/Record/List/ctor    → all cheap fields
  Call (VarLocal …) _, Call (Call …) _ (non-global head), TailCall, Destruct of non-cheap, Shader → False
```

`cost` is the pre-mono inliner's (`InlineSimplify.elm:964`); the kernel classes are
`kernelCostClasses` (`MonoInlineSimplify.elm:1281`, 1/4/8/20) read through KernelFacts, which is
keyed by `(home, name)` and available from a `VarKernel` pre-mono (Q1 R4). `Debug.log` is a kernel
call outside the cheap classes, so a body containing one is declined — which is also the ordering
pin (§5). **What the gate PERMITS**: for a cheap body, a `crash`/`Debug.log` reachable only through
a PAP it builds fires at application time instead of at CAF init — the same observable-ordering
class `arityRaise` accepts (H6.2). Nothing else is observable in Elm.

### 2.6 Scope

IN v1: `Define`/`TrackedDefine` bodies; `Cycle` FUNCTION defs (`Def _ name body tipe`, arity from
`tipe`) — **`sequence` and every recursive `unify`-style caller is a Cycle member**, so this is not
optional; continuation lambdas anywhere in any body. OUT v1: `TailDef` (its `TailCall` sites carry
exactly the syntactic parameters; adding params means threading them through every jump — v2);
Cycle VALUE defs (a recursive CAF); `PortIncoming`/`PortOutgoing`; **kernel-ALIAS nodes — a `Define`/`TrackedDefine`
whose whole body is a bare `VarKernel`** (`cons = Elm.Kernel.List.cons`), because
`LssInfer.kernelAliasOf` (`LssInfer.elm:2713`) recognises them by EXACTLY that
shape and folds the `g|` and `k|` identities into one (LSS_016); η-expanding one
to `\a b -> Elm_Kernel_List_cons a b` hides the alias and joins the split
identities to a 2-set that kills every singleton consumer. elm/core is full of
these, so this is a load-bearing exclusion, not a defensive one — the unit suite
caught it on `List.cons`/`List.map2` before any E2E ran, and the self-compile
census counts 164 of them. Also OUT: `main` and anything whose type
has no arrow spine (declined as `noSpine` — automatically covers `Html msg`/`Program`); values of
alias-arrow type stored in DATA (`List (IO a)` — η fires on definitions and on lambda literals in
argument position only, never on list elements or record fields).

### 2.7 Identity discipline (item 0's contract)

Every subtree this pass BUILDS — the definition wrapper `Function`, each `Call`, each pushed
branch — is constructed with `Nothing` lambda ids and passed ONCE through
`Fresh.mintNewNode`. The rebuilt continuation lambda keeps its id (§2.3). **CORRECTED BY THE VALIDATOR.** This paragraph originally said the types used
are sub-terms of existing typed values that "already carry ids", so `mintNewNode`
would assign only the new wrapper lambdas'. That is WRONG, and `assertMinted`
says so: an `ArrowId` names one syntactic arrow OCCURRENCE (LSS_027), so reusing
a sub-term VERBATIM at a new position puts one id at two occurrences — the
LSS_009 impersonation shape, which `assertMinted` rejects outright. It did:
`elm/bytes:Bytes.Encode.bytes: ArrowId 2154 occurs twice`, on the first
`ECO_MONO_VALIDATE=1` run.

The rule that works is: **every type this pass places at a NEW position has its
arrow slots CLEARED (`Can.noArrow`) first, and one `Fresh.mintNewNode` over the
rebuilt subtree assigns them fresh ids.** New parameter types, every rebuilt
`Call`'s result type, the definition wrapper's own meta, and the beta `Let`'s
meta all go through that. Two places needed it that read as innocent:

  - the bare-value wrapper's meta, because the body it wraps STAYS IN THE TREE
    underneath it, so `metaOf body` would be the same type at two occurrences;
  - the beta `Let`'s meta, for the same reason against its own body — the shape
    `InlineSimplify.doInline` writes as `TOpt.Let … acc (TOpt.metaOf acc)`.

Types that stay at the position they already occupied are reused verbatim: a
rebuilt lambda's own meta and existing params, a callee reference's meta, a
`Def`/`Destructor`, and the lambda parameter type the beta rule moves into its
`Let` (the param list is dropped in the same step). The NODE's own meta is never
touched, so the signature-source type LSS_006 reads its arrow ordinals off does
not move.

Re-minting is also the FAITHFUL reading, not a concession: `AssignMVarIds`'s
Phase-2a fallback mints per syntactic occurrence, and a new parameter's declared
type is a new occurrence.

### 2.8 Config and census

`inline.etaExpand : Bool` on `Compiler.Eco.Config.InlineConfig` (`Config.elm:963+`; 19 fields,
never `LssConfig`), default `False`, `D.optionalField "etaExpand"` next to `:1207`, hash token
`eta=` next to `preInl=` (`:1451`), env `ECO_INLINE_ETA_EXPAND` via `applyInlineEtaExpandOverride`
copied from `applyInlinePreMonoOverride` (`Builder/Eco/Config.elm:1797`, record UPDATE). The cheap
bound reuses `inline.threshold` — no second knob in v1.

Pipeline: `Generate.runMonoOptPipeline` (`Generate.elm:741-770`), after `AliasForward`, before
`LiftClosedArgs` and `InlineSimplify`; signature
`EtaExpand.run : Config.InlineConfig -> GlobalMVarState -> TOpt.GlobalGraph MVarId -> ( TOpt.GlobalGraph MVarId, GlobalMVarState, Metrics )`.

One stderr line when `inline.report` (rendered next to `renderPreInlineReport`):

```
pre-eta: defs=N cycleDefs=N conts=N merged=N pushed=N declined.notCheap=N declined.noDeficit=N
         declined.noSpine=N declined.tailDef=N declined.cycleValue=N declined.kernelAlias=N
         declined.noPeel=N bodiesSeen=N
  deficit: 1=N 2=N 3+=N   cheapShare=N/N
  top: <name>=N …            -- a definition by its own global, a continuation by its CALLEE
  topDeclined: <name>=N …    -- what the cheapness gate refused, so a mis-tuned gate names itself
```

Two counters were added while building. `declined.kernelAlias` is the LSS_016
refusal (§2.6) and is LARGE — 164 on the self-compile — so leaving it out would
have made `bodiesSeen` and the decline columns fail to add up. `declined.noPeel`
is a consistency check whose expected value is ZERO: it fires when the node's
meta type says there are `deficit` arrows to peel and the BODY's type disagrees,
and it declines the site rather than emit something mistyped.

`bodiesSeen` is the denominator whose zero is impossible (the inliner's lesson). A CENSUS-ONLY
mode (`inline.report` on, `etaExpand` off) runs the classifier without rewriting and prints
`pre-eta-census:` with the same fields — Step 1 below, before any rewrite exists.

## 3. Adversarial review

- **R1 — CAF sharing loss. MEASURED, AND IT DOES NOT REACH THE DEFINITION RULE.**
  The concern was `Generate/MLIR/Expr.elm:707`: an arity-0 spec is a memoised CAF
  slot, so after η it would be evaluated per call. `test/elm/src/EtaExpandLogOrderTest.elm`
  was written to pin exactly that — a definition of alias-arrow type whose
  pre-binder work is a `Debug.log`, expected to print once. **The flag-OFF
  baseline printed it THREE times, once per call.** The reason is
  `MonoGlobalOptimize.ensureCallableForNode` (:584): every top-level node whose
  MonoType is an `MFunction` is wrapped by `makeGeneralClosureGO` (:541) into
  `MonoClosure params (MonoCall <original body> params)` — the original body sits
  INSIDE the closure and runs per call. GlobalOpt already performs this same
  η-expansion one phase later, so a definition of alias-arrow type is never a
  memoised CAF to begin with. What η-expansion changes for a definition is WHERE
  the wrapping happens — early enough for the new arguments to merge into the
  under-applied call and for the analysis to see a saturated one — not how often
  the body runs.

  The gate is kept anyway, for two reasons that survive: it is load-bearing for
  the CONTINUATION rule (a lambda's body moves from once per closure application
  to once per SECOND application, and a continuation's result CAN be shared), and
  it keeps the transform's blast radius small while the flag is young. The census
  reports `cheapShare`; on the self-compile it is 84/194 (§9).

- **R2 — specialization budget.** `andThen` has 425 specs on the self-compile; saturation keys one
  spec per `(f, ma)` demand. Past `maxSpecsPerGlobal` (`Config.elm:240`) new demands are
  set-WIDENED — a regression mode, not a crash. Gate: record `registry countByGlobal` for
  `andThen`/`map` in both arms; if the cap is hit, raise it for the experiment and report both.
- **R3 — Fact 2.** Needs no ground types (§2.1). A definition whose type is a bare variable has no
  spine and is declined (`noSpine`); `a -> b` with `b` a variable has arity exactly 1 — correct.
- **R4 — interaction with the inliner.** The inliner's `hofParam` guard still declines `andThen`;
  that is fine — the η'd continuations are arity-2 lambda LITERALS in argument position, which mint
  `l|` members with singleton sets (LSS_017/024). The win needs no inlining. If item 5 later admits
  `andThen`, the saturated shape is the one it wants anyway.
- **R5 — item 4 ordering.** `declaredArity g` must be the forwarded target's; running after
  `AliasForward` guarantees it. If item 4 is off, an alias wrapper `f = g` has arity 0 syntactically
  and its declared arity from its type — still correct, just a wrapper call.
- **R6 — LSS_003/LSS_013.** No ids are minted here except through `mintNewNode` (LSS_003's single
  minting authority is preserved by contract). LSS_013's result-spine injection sees a SHORTER spine
  on η'd values — that is the intended effect: the value is now applied where it was built. A global
  referenced as a VALUE (`tick` as a list element) is a `g|` member as before (report §4.0 row 2).
- **R7 — `TailDef`.** Excluded; documented in §2.6 with the reason.
- **R8 — pushing into `Case`.** Both `Inline` choices in the decider and `jumps` must be rewritten,
  or a shared branch keeps the un-applied PAP while its siblings are saturated — a type error mono
  would catch, but the unit fixture in §5 pins it structurally.
- **R9 — byte-identity at defaults.** With the flag off the pass is not run at all (the
  `runMonoOptPipeline` gate), so no alias expansion or walk happens — zero cost, byte-identical.
- **R10 — deps.** Unchanged: the rewrite references no global that the body did not.
- **R11 — dead specs inflate static counts.** In the `both` arm the post-mono inliner leaves dead
  `andThen` specs with generic sites inside (report §7). Every measurement here counts LIVE sites
  (dispatch) or filters by liveness; a static `_call_kind` histogram is not evidence.

## 4. Lowered steps

| # | change | files | status |
|---|---|---|---|
| 0 | Flag `etaExpand`, decoder, hash `eta=`, env override, pipeline hook (pass not called when off) | `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm`, `Builder/Generate.elm` | **DONE** |
| 1 | `spine`/`substTypeVars`/`declaredArity` + CENSUS-ONLY mode printing `pre-eta-census:`; `rewriteCanType`'s `TAlias` arm verified (§2.1) | `PreMono/EtaExpand.elm` | **DONE** — census in §9 |
| 2 | Definition rule (§2.2) + merge/push/beta normaliser (§2.4) + `mintNewNode` | `EtaExpand.elm` | **DONE** — F1–F3 green; `EtaExpandStateTest` prints `r: [30, 42, 54]` in both arms |
| 3 | Continuation rule (§2.3) | `EtaExpand.elm` | **DONE** — F4 green; output identical to the HAND-written `SeqEta` (§9) |
| 4 | Cycle `Def` rule; `TailDef`/value-def declines counted | `EtaExpand.elm` | **DONE** — F5, F6 green |
| 5 | Cheapness gate + `declined.notCheap` | `EtaExpand.elm` | **DONE** — F7, F8 green |
| 6 | `assertMinted` run under `mono.validate` after the pass | `Generate.elm` (already there from item 0) | **DONE** — and it CAUGHT a real duplicate-`ArrowId` defect, §2.7 |
| 7 | Standing gates | — | **DONE** — see §9 |
| 8 | Measurement (§6) | `benchmarks/lss-opt.md` | **NOT RUN** — blocked, see §9.4 |

Estimated size: ~450 lines of Elm in `EtaExpand.elm`, ~60 lines of plumbing.

## 5. Tests

`TestLogic/GlobalOpt/EtaExpandTest.elm` (SourceBuilder; alias via `AliasDef { name = "St", args =
["a"], tipe = tLambda (tType "Int" []) (tTuple (tType "Int" []) (tVar "a")) }` — verify `tVar`
exists, else `tType "a" []`; module via `makeModuleWithTypedDefsUnionsAliases`, `:843`). After item
0 the harness exposes a `runToAssigned`; each fixture runs `EtaExpand.run` on its graph and asserts
structurally with a small walk:

| # | fixture | pins |
|---|---|---|
| F1 | `prog : St Int; prog = tick \|> andThen (\a -> pure a)` | node body becomes `Function` with 1 param; the inner `andThen` call has 3 args (`merged=1`); the continuation has 2 params (`conts=1`) |
| F2 | `d : St Int; d = tick` (bare global) | `Function [s] (Call tick [s])`, `defs=1` |
| F3 | `d : Int -> St Int; d n = tick` (partial syntactic arity) | one param appended, 2 total |
| F4 | continuation with an existing 2nd param `(\a s -> …)` | untouched, `conts=0` |
| F5 | `sequence`-shaped recursive def (Cycle `Def`) | `cycleDefs=1`; both `case` branches saturated (R8) |
| F6 | tail-recursive `TailDef` with deficit | `declined.tailDef=1`, body unchanged |
| F7 | `d = let big = expensive 1 in pure big` | `declined.notCheap=1` |
| F8 | `d = pure (expensive 1)` — the same refusal reached through an ARGUMENT | `declined.notCheap=1` |
| F9 | a definition whose type has no arrow spine | `declined.noSpine` — never touched |
| — | **the graph's kernel aliases are refused** | `kernelAlias >= 2` (LSS_016, §2.6) |

**As built, the fixtures deviate from the sketch above in two ways, both forced
by the harness.** (a) The state alias is `St a = Int -> a` rather than
`Int -> ( Int, a )`: `Tuple` is not in `SourceBuilder.standardImports`, and a
one-element state changes nothing the transform reads — the arity still lives
entirely in the alias. (b) F7/F8 use a locally-defined over-threshold
`expensive` instead of `Debug.log`, because the harness has no `Debug`
interface; `Debug.log` reaches the same refusal (`VarDebug` is admitted by no
cheap arm) and its observable half is pinned end-to-end instead. The
kernel-alias row was NOT in the sketch — it exists because the pass expanded
`List.cons` and `List.map2` on its first run, which is the LSS_016 hazard of
§2.6.

`test/elm/src/EtaExpandStateTest.elm`: the `SeqM` source VERBATIM (un-expanded — the compiler must
produce `SeqEta`'s result), `-- CHECK: r: [30, 42, 54]`, run in both arms and with the flag on/off.
A second module `EtaExpandLogOrderTest.elm`: a definition of alias-arrow type whose pre-binder work
is `Debug.log "init"`, called three times, plus a cheap chain that IS expanded. A `CHECK-NEXT` chain
pins the exact interleaving — which turns out to be `init` once per call in BOTH arms, because
`ensureCallableForNode` already wraps every function-typed node per call (the R1 correction). That
makes it a strict ordering guard rather than the CAF pin it was written as: if η-expansion ever
re-timed anything, the chain breaks.

## 6. Measurement

1. **Census first** (Step 1), self-compile, `ECO_INLINE_REPORT=1`, flag off: deficit histogram and
   `cheapShare`. On `IO a`-typed definitions and continuations this is the whole 55 %; if
   `cheapShare` is low the gate is mis-tuned before any run is spent.
2. **Two-arm protocol run** per `benchmarks/lss-opt.md` (one cold run per arm, census off, no probe):
   arms `eta=0` / `eta=1`, everything else at DEFAULTS (`postMono=1`, `preMono=0`) — the shipping
   configuration. Record wall, minors, majors, promoted, `out.mlir` size, and the `lss globalopt:`
   line (`dispatchUpgraded`, `declinedNoInstance`, `multiInstanceGroups`) plus `andThen`/`map`
   spec counts (R2).
3. **Dispatch**, separate uprobe run on each arm's lowered compiler: `sudo -n`, mount tracefs +
   debugfs first, `uprobe:BIN:eco_apply_closure_eval { @gen[*(uint64*)reg("sp")] = count(); }`,
   `BPFTRACE_MAP_KEYS_MAX` raised (default 4096 truncates silently), symbolised by return address to
   the `System_TypeCheck_IO_andThen_$_*` / `_map_$_*` specs. Headline = generic dispatch at those
   specs, LIVE only. The prior: −1.11 e9 came from the P0 hand rewrite of one module; this targets the
   remaining 27.6 % (#2+#3 after P0-P3).
4. Then the EARLY configuration (`preMono=1 postMono=0`, item 2's `preserveSets` if landed) as a
   second experiment, not the headline.

## 7. Risks — as resolved

- ~~The gate refuses the hot sites.~~ MEASURED: `cheapShare` is 84/194 on the
  self-compile's dependency closure (§9.1). Not obviously mis-tuned; the real
  test is the IO-monad arm, which is blocked (§9.4).
- Spec explosion at `andThen` (R2) — still unmeasured, because the measurement
  run is blocked. Watch `countByGlobal`; the widening past the cap is silent.
- ~~A `Case` push that misses `jumps` (R8).~~ F5 pins it, and the `sequence`
  fixture exercises it end-to-end.
- ~~The `TAlias` occurrence-id assumption (§2.7).~~ Verified; and the OTHER half
  of §2.7 was wrong and was corrected by the validator.
- **NEW, and the one that matters:** the transform produces the source shape
  that reaches a PRE-EXISTING miscompile in `lss.refIdentity` + `devirt.post`
  (`/work/combinator-uf-devirt-error.md`). It is not caused by this pass —
  writing the same parameters by hand with the flag OFF reproduces it — but it
  blocks turning the flag on. §9.4.

## 8. What not to do

- Do not η-expand PAP ARGUMENTS (`applyI (add 5)` → `applyI (\v -> add 5 v)`): MEASURED negative,
  17 → 12 stamps (report §3.1). LSS_040 already stamps `p|`; an `l|` lands in `g1absentl`.
- Do not substitute arguments into bodies; Let-bind, as the inliner does.
- Do not read `AnnotationsByGlobal` for arity; the node meta is always present and equal.
- Do not run the pass before `AliasForward` — the wrapper's arity would be read.
- Do not judge this on a static `_call_kind` count in the `both` arm (R11); count live dispatch.
- Do not touch `TailDef`, ports, `main`, or data-stored actions in v1.
- **Do not read a callee's arity off its TYPE.** An arrow chain counts the
  arrows of its RESULT; the graph's syntactic parameter count is the only thing
  that says where the first stage ends. Learned from a miscompile, §2.4.
- **Do not η-expand a kernel-ALIAS node.** LSS_016 recognises `Define (VarKernel …)`
  by shape and folds two identities into one; expanding it splits them. §2.6.
- **Do not splice an existing type sub-term at a NEW position.** Clear its arrow
  slots first and let `mintNewNode` re-mint. §2.7.
- Do not add the `/work/combinator-uf-devirt-error.md` reproducer to
  `test/elm/src/` while it is unfixed: it fails at DEFAULTS and would redden the
  standing gate for every unrelated change.


---

## 9. Results (2026-09-10)

### 9.1 What was built

`compiler/src/Compiler/GlobalOpt/PreMono/EtaExpand.elm` (2,032 lines, roughly
half of them documentation; the estimate was ~450 lines of code, which is about
right once the comments are subtracted), called from `Builder/Generate.elm`'s
`runMonoOptPipeline` immediately after `EntryPrep.assign` and BEFORE the
pre-mono inliner (§2.8's placement), so the inliner sees saturated calls rather
than the 2-of-3 PAPs its `hofParam` guard declines. `AliasForward` (item 4) and
`LiftClosedArgs` (item 3) do not exist yet; when they land, item 4 goes in front
of this pass and item 3 behind it.
Plumbing: `inline.etaExpand` on `InlineConfig`, its decoder field, the `eta=`
hash token, `applyInlineEtaExpandOverride` for `ECO_INLINE_ETA_EXPAND`.

With BOTH `inline.etaExpand` and `inline.report` off the pass is not called at
all, so the default path does not even walk the graph (R9). `inline.report`
alone runs it as a census — the classifier runs, the graph and the id allocator
come back untouched, and the line is prefixed `pre-eta-census:` so a log cannot
be misread as evidence the rewrite happened.

### 9.2 The headline: the compiler reproduces the hand rewrite EXACTLY

`test/elm/src/EtaExpandStateTest.elm` is the `SeqM` probe verbatim — the chain
written at ALIAS arity. Compiled with the flag on and normalised against the
HAND-written `SeqEta` from `scratchpad/q4probe/src/` (module name, SSA numbers,
lambda ids, spec ordinals and the η binder names folded together):

```
auto lines 367   hand lines 367   diff: ONE line
-  %V = "eco.call"(%V) … callee = @Elm_Kernel_VirtualDom_text
+  %V = "eco.call"(%V) … callee = @VirtualDom_text_$_N
```

That single difference is `Html.text` in `main`, which η never touches; it comes
from the two probes' separate build directories resolving the kernel alias
differently. Op histograms are identical to the digit
(`papCreate` 8, `papExtend` 16, `call` 18, `case` 9, …). **The transform
produces the hand rewrite, not merely something like it.**

Output `r: [30, 42, 54]` in every arm.

### 9.3 Gates

| gate | result |
|---|---|
| unit suite, whole compiler | **13,497 passed / 12 failed** — the 12 are the pre-existing POST_010 orphan-TVar failures; the baseline was 13,474, and this plan adds 23 |
| E2E at DEFAULTS (`build/test/test`, 1,723 tests) | **1,723 / 1,723 PASSED** |
| E2E with `ECO_INLINE_ETA_EXPAND=1` | **1,720 / 1,723** before the E9.5 fix — three failures, all diagnosed in §9.4; after it, only the two MLIR-shape pins remain (see the fix's own gates in `/work/combinator-uf-devirt-error.md` §8) |
| E2E with `ECO_INLINE_ETA_EXPAND=1 ECO_MONO_VALIDATE=1` | **1,720 / 1,723** — the SAME three. `Fresh.assertMinted` and the MONO_029 layout validator are clean across 1,723 programs with the flag on |
| E2E with `ECO_MONO_VALIDATE=1` at defaults (the control) | **1,723 / 1,723** — so the three above are not validator noise |
| `ECO_INLINE_THRESHOLD=0` leg with the flag on | **1,721 / 1,723** — only the two MLIR-SHAPE failures. `CombinatorTest` PASSES, which is the third independent confirmation that its wrong answer is the LSS/post-mono-inliner interaction and not this transform. No transform has become a correctness dependency |
| `ECO_INLINE_THRESHOLD=0` at defaults (the control) | **1,723 / 1,723** |
| `.mlir` byte-identical at defaults | by construction — the pass is not called (R9). The `eta=` hash token changes the DETAILS CACHE key only (`Terminal/Make.elm:219`), never emitted code |
| EARLY arm (`preMono=1 postMono=0`) with the flag on | **1,715 / 1,723**, against a control of **1,717 / 1,723** for the same arm WITHOUT the flag. η adds exactly the two MLIR-shape failures and nothing else; the six the control already fails (`AndThenProbe`, five `Hof*`) are the pre-existing `postMono=0` set. `CombinatorTest` PASSES here, since without the post-mono inliner the wrong lambda set is never realised |
| self-compile census | §9.5 |
| protocol run (§6.2) | **Run AV in `benchmarks/lss-opt.md`** — single arm as commissioned (`etaExpand=1`, else defaults): 478.7 s vs AT-late 472.3 s = +1.4 %, FLAT; majors 9→11 to watch; `pre-eta` on the self-compile: defs=450 cycleDefs=46 conts=311 merged=634, cheapShare 807/1,175; `dispatchUpgraded` +745, `stampedPapGlobal` +392. The `eta=0` arm is still owed. §6.3's dispatch census exists as ONE arm: `benchmarks/runtime-calls.md` Run AP (eta-BUILT compiler, `ECO_CALL_CENSUS` + `ECO_DISPATCH_STATS`): fast 52.92 % of 1.67 B logical dispatches, gen 42.12 %, typed 4.96 %; static-target share 94.54 %; sets k1 68.4 % / kN 23.3 % / var 7.5 % / ⊤ 0.7 % |

The validator run is the one that earned its keep twice: it caught a real
duplicate-`ArrowId` defect during development (§2.7), and it is what turns
"the three failures are not identity bugs" from a hope into a measurement.

### 9.4 The three flag-on failures, and the one that blocks the flag

**1. `elm/CombinatorTest.elm` — a WRONG ANSWER, and it is NOT this pass.**
`b square inc 4` prints 64 instead of 25. Written out in full:
`/work/combinator-uf-devirt-error.md`. Two `s` specializations share an ABI,
and `lss.refIdentity` + `lss.devirt.post` let one demand's singleton member
reach the other's `uf` parameter, which `MonoInlineSimplify` then inlines as
`double` inside the specialization `b` calls.

η-expansion does not cause it. **Writing the same three parameters BY HAND with
the flag OFF reproduces it exactly** — `b f g y = s (k s) k f g y` prints 64 at
defaults today.

Why `CombinatorTest.elm` was green before: it is written POINT-FREE, and the
wrong specialization is present either way. Both spellings emit an `s` spec
whose `uf` is devirtualized to `double`; the point-free `b` is a 2-of-3 PAP, so
its whole chain stays in the all-boxed `(value,value,value) -> value` spec and
never reaches it. Giving `b` parameters lets mono see `y : i64`, the post-mono
inliner beta-reduces `s (k s) k f` to `s (k f)`, and the residual call lands on
`(value, value, i64) -> i64` — the same ABI as `s (+) double 5`, where the two
demands are neighbours. The full-arity arm even BUILDS the right spec (`uf` :=
`inc`) and leaves a dead reference to it beside the live wrong one. Bisected: `ECO_MONO_LSS=0`,
`ECO_MONO_LSS_REF_IDENTITY=0`, `ECO_MONO_LSS_DEVIRT_POST=0` and
`ECO_INLINE_POST_MONO=0` each give 25; eleven other LSS levers change nothing;
`ECO_MONO_VALIDATE=1` is silent, because the defect is a wrong SET, not a wrong
id.

**FIXED 2026-09-10.** Traced to `AbiCloning.matchSpec` (E9.5, LSS_025)
choosing the MINIMUM SpecId among same-layout registry specs of the target;
`#6` (`uf := double`) and `#10` (`uf := inc`) both matched the layout and `#6`
was smaller. The rule is now UNIQUENESS (exact type match, else unique layout
match, else `PsAmbiguous`), `CombinatorTest` passes with the flag on, and
`test/elm/src/CombinatorRefIdentityBugTest.elm` pins the full-arity spelling.
§6's measurement run is unblocked.

**2. `elm/CrossStageCallKindTest.elm` — the transform doing its job.**
`-- CHECK-MLIR: segmentation_unknown` asserts a generic cross-stage `papExtend`
is PRESENT. `caseFunc : Int -> Int -> Int -> Int` is written with one parameter
and a `case` returning differently staged lambdas; η pushes the two new
arguments into the branches and betas the lambdas, so the generic op the fixture
pins is gone. The VALUE check (`result: 8`) still passes. A fixture that pins
the presence of the thing being removed will need a flag-conditional note when
the flag ships on.

**3. `elm-bytes/FusionGlobalMapFnTest.elm` — a real optimization interaction.**
`-- CHECK-MLIR: bf.write.u8` no longer matches: `E.Encoder` expands to an arrow,
so `encodeByte n = E.unsignedInt8 n` gains a parameter and bytes-fusion's
`reifyMapBody` `MonoVarGlobal` arm no longer recognises the mapFn body it
beta-reduces. The VALUE check (`FusionGlobalMapFnTest: 7`) still passes, so this
is a lost fusion, not a wrong answer. Bytes fusion would need to look through
the extra parameter before the flag ships on.

### 9.5 Census

`ECO_INLINE_REPORT=1` with the flag off, over the full dependency closure of an
E2E fixture (user module + elm/core + elm/html + elm/bytes — 664 bodies):

```
pre-eta-census: defs=81 cycleDefs=1 conts=2 merged=60 pushed=3
  declined.notCheap=110 declined.noDeficit=267 declined.noSpine=18
  declined.tailDef=0 declined.cycleValue=0 declined.kernelAlias=164
  declined.noPeel=0 bodiesSeen=664
  deficit: 1=71 2=114 3+=9   cheapShare=84/194
```

**This line is also the tightest regression check the pass has**, and it earned
that during the build. Two later refinements each moved it by ONE continuation,
and one continuation is the difference between reproducing the hand rewrite and
not:

  - reading the callee's arity from the graph made `\x -> sequence rest` look
    like a SATURATED call to something expensive — `conts` 2 → 1 — which the
    two-round `Gate.arity` (§2.4) fixed;
  - the same change made `x :: xs` refuse, because `List.cons` is a kernel alias
    whose graph arity is 0, so every call to one was refused — `conts` 2 → 1
    again, by a completely different route, which `Gate.aliasCost` fixed.

Neither showed up as a test failure. `EtaExpandStateTest` still printed
`r: [30, 42, 54]`; only §9.2's line-for-line comparison against the hand rewrite
and this census moved. That is the argument for keeping both.

Three things to read off it:

  - `declined.kernelAlias=164` — a QUARTER of every body examined is an eta-free
    kernel alias. Without the LSS_016 refusal (§2.6) this pass would have
    rewritten all of them.
  - `cheapShare=84/194` — the gate admits 43 % of what the arity test offers.
    Not obviously mis-tuned; `topDeclined` names `Html.*`/`Html.Attributes.*`
    builders, which are saturated calls over `inline.threshold`.
  - `declined.noPeel=0`, as designed: the node meta and the body type never
    disagreed about how many arrows there were to peel.

The IO-monad numbers this plan is actually aimed at need the compiler's own
self-compile. It was attempted on this host (JS-hosted `guida.js`,
`--max-old-space-size=16384`) and was killed by the system at ~158/261 modules
for memory: the machine has 15 GB in total and the JS self-compile needs 12–16
(memory: `eco-jsselfcompile-needs-16gb-heap`). It belongs with the §6 protocol
run, on the native compiler, on a larger host — §9.4's blocker is now fixed, so
nothing else stands in its way.

## AMENDMENT 2026-09-11 — bootstrap fixed point for eta=1 (owed from §6) ROOT-CAUSED

The η-built compiler was not a fixed point because it was a WRONG compiler, and the defect is
a pre-existing LSS miscompile that η exposes, not an η defect: the E9.5 post-settle `p|` fast
stamp (LSS_040 `lss.stamp.papFast`) fires on `{p|Engine.succeed|1} ⊔ var` in `translateLet`'s
`case singleInstance of Just -> andThen … (loadType …); Nothing -> Engine.succeed ()` after the
settle pass attributes the var away, so the `Just` branch's demand binding is silently skipped.
Bisected to `Engine.succeed` alone; reproduced η-free by a 60-line program (prints 31, expects 42).
With `ECO_MONO_LSS_PAP_FAST=0`, full η IS a bootstrap fixed point (fpA == fpB, 15,637,214 B).
Full account: `/work/eta-fixed-point-root-cause.md`. Diagnostic kept: `ECO_INLINE_ETA_ONLY`.

## AMENDMENT 2026-09-11 (afternoon) — the LSS defect FIXED; η ships default-on

- Root cause of the false singleton (precise): `Translate` never connected a `Destruct`/`Let`
  WRAPPER's body type to the wrapper's own node type, so a pattern-binding branch's call
  result set stayed in a disconnected arrow slot while a bare `succeed ()` PAP branch wrote
  `{p|succeed}` into the case slot. Fix: `connectTypes (TOpt.typeOf body) meta.tipe` in the
  `TOpt.Let` and `TOpt.Destruct` arms (+ `joinBranchTypes` hardening of the residual-MVar
  case/if fallbacks). Regression test `test/elm/src/PapStampTest.elm` (η-free, prints 42).
- §9.4 fixtures: `CrossStageCallKindTest` now routes `caseFunc`'s scrutinee through
  `Debug.log` (never cheap ⇒ η refuses it; shape pin survives under either flag);
  `FusionGlobalMapFnTest` is fixed properly — `BytesFusion.Reify.reifyMapBody` η-reduces an
  η-expanded 2-parameter helper (`etaReduceTrailingParam`) before recognition, so the fusion
  is no longer lost under η.
- Gates: E2E 1725/1725 with the fix (defaults); bootstrap chain and η-on E2E arm recorded in
  /work/eta-fixed-point-root-cause.md §6/§8.
- §2.6 addendum (2026-09-11): a definition whose whole body is a bare CONSTRUCTOR reference
  (`unsignedInt8 = U8`; `VarGlobal` to a `TOpt.Ctor` node, or `VarBox`/`VarEnum`) is never
  expanded — `isCtorAlias` over `Gate.ctors`, counted as `declined.ctorAlias`. Expanding it buys
  no arity and turns a non-inlinable CAF-alias call into an inlinable one, which hid the
  constructor from bytes fusion's name-keyed recogniser (`FusionGlobalMapFnTest`).
- DEFAULT FLIPPED: `inline.etaExpand = True` (`ECO_INLINE_ETA_EXPAND=0` turns it off).

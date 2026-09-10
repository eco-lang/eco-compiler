# Pre-mono LSS transforms — 01: η-expand definitions and continuations to declared arity

**Status:** IMPLEMENTATION-READY (2026-09-10). Item 1 of `plans/pre-mono-lss-transforms.md`.
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
`At`/`toRegion :147`); `deps` unchanged (no new globals are referenced); the node `meta` unchanged
(the Function's type IS the definition's alias-typed arrow, exactly the shape `tick s = …` already
has in the probes). Fresh names `_eta<n>` from a per-pass counter: Elm identifiers cannot begin
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

`declaredArity g` for a global comes from the graph (`bodyOf`-style lookup, `InlineSimplify.elm:809`);
after item 4 the callee is the forwarded target, so an alias wrapper's arity is never read.

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
Cycle VALUE defs (a recursive CAF); `PortIncoming`/`PortOutgoing`; `main` and anything whose type
has no arrow spine (declined as `noSpine` — automatically covers `Html msg`/`Program`); values of
alias-arrow type stored in DATA (`List (IO a)` — η fires on definitions and on lambda literals in
argument position only, never on list elements or record fields).

### 2.7 Identity discipline (item 0's contract)

Every subtree this pass BUILDS — the definition wrapper `Function`, each `Call`, each pushed
branch — is constructed with `Nothing` lambda ids and passed ONCE through
`Fresh.mintNewNode`. The rebuilt continuation lambda keeps its id (§2.3). All TYPES used are
sub-terms of existing typed values (the node meta, the expanded spine of an annotation OCCURRENCE,
the callee reference meta) and already carry ids; `mintNewNode` is therefore expected to assign
only the new wrapper lambdas' ids, and `assertMinted` under `mono.validate` checks that nothing is
left `Nothing`/`NoArrow`. Step 1 must VERIFY by reading `AssignMVarIds.rewriteCanType`'s `TAlias`
arm that ids are minted inside `Holey`/`Filled` bodies per annotation occurrence; if not,
`mintNewNode` fills them, and the plan's assumption that no two definitions share an expanded
arrow id must be re-checked.

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
         declined.noSpine=N declined.tailDef=N declined.cycleValue=N bodiesSeen=N
  deficit: 1=N 2=N 3+=N   cheapShare=N/N   top: andThen=N map=N …
```

`bodiesSeen` is the denominator whose zero is impossible (the inliner's lesson). A CENSUS-ONLY
mode (`inline.report` on, `etaExpand` off) runs the classifier without rewriting and prints
`pre-eta-census:` with the same fields — Step 1 below, before any rewrite exists.

## 3. Adversarial review

- **R1 — CAF sharing loss.** `Generate/MLIR/Expr.elm:707`: an arity-0 spec is a memoised CAF slot;
  after η it is an arity-≥1 function, evaluated per call. For an IO action the CAF VALUE was a
  PAP/closure, not a computed result, so nothing is lost; for an expensive value it would be
  recomputed per call. Resolved by the gate (§2.5): only bodies whose pre-binder work is PAP/closure
  construction or a sub-threshold call are expanded. The census's `cheapShare` measures how much
  the gate refuses; if it refuses most of the 55 %, the gate is wrong, not the idea.
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

| # | change | files | gate |
|---|---|---|---|
| 0 | Flag `etaExpand`, decoder, hash `eta=`, env override, pipeline hook (pass not called when off) | `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm`, `Builder/Generate.elm` | `.mlir` byte-identical at defaults; fixed point |
| 1 | `spine`/`substTypeVars`/`declaredArity` + CENSUS-ONLY walk printing `pre-eta-census:`; verify `rewriteCanType`'s `TAlias` arm (§2.7) | `PreMono/EtaExpand.elm` | self-compile census recorded in this plan: deficit histogram, `cheapShare`, top callees; unit test on the spine |
| 2 | Definition rule (§2.2) + merge/push/beta normaliser (§2.4) + `mintNewNode` | `EtaExpand.elm` | unit fixtures F1–F3; `EtaExpandStateTest` at defaults prints `r: [30, 42, 54]` |
| 3 | Continuation rule (§2.3) | `EtaExpand.elm` | fixture F4; `EtaExpandStateTest` in the EARLY arm: LIVE generic ≤ 1 (the GAP-6 residual) |
| 4 | Cycle `Def` rule; `TailDef`/value-def declines counted | `EtaExpand.elm` | fixture F5 (`sequence`-shaped recursion expands), F6 (`TailDef` declined) |
| 5 | Cheapness gate + `declined.notCheap` | `EtaExpand.elm` | fixture F7 (expensive `let` declined), F8 (`Debug.log` body declined) |
| 6 | `assertMinted` run under `mono.validate` after the pass | `Generate.elm` | self-compile with `mono.validate` clean, flag on |
| 7 | Standing gates | — | both-arm E2E 887/889; `ECO_INLINE_THRESHOLD=0` leg; smoke fixtures; fixed point |
| 8 | Measurement (§6) | `benchmarks/lss-opt.md` | Run recorded; verdict per the 3 % bar |

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
| F7 | `d = let big = List.range 1 100000 \|> List.sum in \s -> …` | `declined.notCheap=1` |
| F8 | `d = Debug.log "x" () \|> always tick` | `declined.notCheap=1` (the ordering pin, structurally) |
| F9 | `main : Html msg` | `declined.noSpine` — never touched |

`test/elm/src/EtaExpandStateTest.elm`: the `SeqM` source VERBATIM (un-expanded — the compiler must
produce `SeqEta`'s result), `-- CHECK: r: [30, 42, 54]`, run in both arms and with the flag on/off.
A second module `EtaExpandLogOrderTest.elm`: a non-cheap CAF containing `Debug.log "init"` followed
by three calls — CHECK pins `init` printed BEFORE the first result; the count cannot be pinned by
CHECK (substring match), so F8 is the pin that it was declined.

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

## 7. Risks

- The gate refuses the hot sites (a continuation whose body is a saturated call over the bound).
  Mitigation: the census names the top declined callees; raise the bound for the experiment and
  measure, never widen the cheap classes by argument.
- Spec explosion at `andThen` (R2) — watch `countByGlobal`; the widening past the cap is silent.
- A `Case` push that misses `jumps` (R8) — pinned by F5.
- The `TAlias` occurrence-id assumption (§2.7) — verified at Step 1 before anything is built.

## 8. What not to do

- Do not η-expand PAP ARGUMENTS (`applyI (add 5)` → `applyI (\v -> add 5 v)`): MEASURED negative,
  17 → 12 stamps (report §3.1). LSS_040 already stamps `p|`; an `l|` lands in `g1absentl`.
- Do not substitute arguments into bodies; Let-bind, as the inliner does.
- Do not read `AnnotationsByGlobal` for arity; the node meta is always present and equal.
- Do not run the pass before `AliasForward` — the wrapper's arity would be read.
- Do not judge this on a static `_call_kind` count in the `both` arm (R11); count live dispatch.
- Do not touch `TailDef`, ports, `main`, or data-stored actions in v1.

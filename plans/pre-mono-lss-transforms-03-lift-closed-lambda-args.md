# Pre-mono LSS transforms — 03: lambda-lift CLOSED lambda arguments

**Status:** **CLOSED UNBUILT** (2026-09-12) — §5's census ran and the premise did not survive it.
Every `g1absentl` on the self-compile is manufactured by the POST-mono inliner (0 remain with
`ECO_INLINE_POST_MONO=0`), so there is no genuine class for a PRE-mono lift to repair. Findings,
numbers and the successor question are in §11; §1–§10 are the design as it stood, kept because the
census instrument (`PreMono/LiftClosedArgs.elm`, §3.1's predicate) is retained and still reads them.
Item 3 of `plans/pre-mono-lss-transforms.md`.

**Origin:** `/work/pre-mono-transformation.md` §3.4/§4.C; `scratchpad/q4-shapes-for-lss.md` §2.C
(probes `LiftLam`/`LiftFn`, `$SP/q4probe/src`). Depends on item 0 (`TOpt.GlobalGraph MVarId`,
`GlobalMVarState` threaded, `PreMono/Fresh.elm`). Runs after item 1 (η-expansion) and before
`InlineSimplify`.

## 1. Problem

### 1.1 The class

`g1absentl`: an AbiCloning call site whose callee arrow carries a SINGLETON `l|` member that has
NO instance in the index. Decline site: `AbiCloning.postSettleTarget`, `AbiCloning.elm:2349` —
`PsNotCandidate ("g1absent" ++ kind)` when `Dict.get m ctx.origins` is `Nothing`, counted through
the `PsNotCandidate why` arm at `:1662` (`bumpNiGuard`). The index is built by `collectInstances`
(`:292`) → `collectClosure` (`:387`), which indexes a `MonoClosure` under `instanceMember`
(`:661-677`): `closureInfo.lssMember`, else `srcLambda`, else a singleton-head ADOPTION. A member
with a site but no indexed instance is exactly this class. Decline census #4: **1,439 sites** on
the self-compile (MEASURED, site count only; dispatch weight UNMEASURED).

### 1.2 What the probe actually shows — and it reframes the item

`LiftLam` (`myFromList assocs = List.foldl (\( k, v ) d -> Dict.insert k v d) Dict.empty assocs`)
compiled with `eco-q1b`, solver+LSS+report, MLIR call kinds read from `mlir-opt` text (MEASURED,
this plan, `$SP/q4probe/LL-*.{err,txt}`):

| arm | post-mono census | callback closure symbol | call kinds | `declinedNoInstance` |
|---|---|---|---|---:|
| defaults | `inlined=5 loopified=1/1` | `@_tail_mono_inline_1_23` | 1 `direct_known_segmentation`, **1 `generic_apply`** | 1 (`g1absentl=1`) |
| `ECO_INLINE_THRESHOLD=0` | `inlined=0 loopified=1/1` | `@_tail_mono_inline_0_22` | same | 3 |
| **`ECO_INLINE_LOOPIFY=0`** | `inlined=5 loopified=0/0` | `@LiftLam_lambda_2` | **1 `singleton_fast`** | **0** |
| EARLY (`preMono=1 postMono=0`) | — | `@LiftLam_lambda_1` | **1 `singleton_fast`** | 2 (elsewhere) |

**The `g1absentl` in this shape is produced by `loopify`.** `tryLoopify`
(`MonoInlineSimplify.elm:2020-2069`) rebuilds the qualifying callback closure with
`captures = []` (`:2148`) and substitutes it as the callee of the loop body's callback calls
(`:2298-2305`); the rebuilt closure is named through `freshVar` (`"mono_inline_" ++ n`, `:2584`)
and emitted as `_tail_<name>_<op>` (`Generate/MLIR/Expr.elm:5817`). It carries no `lssMember`, so
one residual application of it inside the loop is `generic_apply` and its member has no instance.
With loopify off the untouched literal is `singleton_fast`. The EARLY arm — no post-mono pass at
all — is also `singleton_fast`.

Consequences for this item:

1. **The lift's mechanism on this shape is loopify DEFEAT, not member repair.** A `VarGlobal`
   argument does not qualify at `:2036` (`( Just lamArity, MonoClosure cinfo cbody ctype )` is the
   only arm), so loopify never fires, the reference mints a `g|` head (E9,
   `Translate.injectArgLambdaMemberGo` `:4424`), mono substitutes the global into the keyed
   `List.foldl` spec (`g2global`), and the call is `eco.call`. That is what `LiftFn` measured.
   Whether it is BETTER than a loopified body with one residual generic apply is a dispatch
   question, not a stamping one.
2. **The self-compile's 1,439 are of unknown origin.** Some are loopify/tail-mono-inline
   artifacts (owned by the post-mono pass — item 2's family), some are `wrapperHome` blockers
   (`:680`), some are genuine `l|` members whose closure was never indexed. Only the last class is
   this item's, and only its CLOSED subset. §5's census splits all three.

## 2. What the lift does

For a closed lambda literal `L` in argument position of a HOF call, create a top-level
`Define L` under a fresh `Global` and replace the argument with a reference to it. LSS then sees
the shape it resolves completely for globals: `injectArgLambdaMemberGo`'s `VarGlobal` arm mints
`g|<lifted>` at the callee's param arrow; the keyed spec of the HOF is minted on that demand and
`translateVarRef` → `classifyRef` → `enqueueSpecStamped` (`Translate.elm:601-613`, and the
function at `:~ 620`) gives the reference its own spec; inside the HOF spec the callback call is
direct. No annotation is required for that path: `lookupAnnotation` (`:8090`) is `Maybe`-valued
and only `translateCall` (`:1948`, falling back to `funcMeta.tipe`) and the ctor path (`:2571`)
consult it — a lifted global is REFERENCED, never called by name at its creation site.

## 3. Design

### 3.1 Scope predicate (v1) — all syntactic, Fact-2-immune

A `Function`/`TrackedFunction` literal `L` qualifies iff:

  - it is an ARGUMENT of a `Call region callee args meta` whose `callee` is `VarGlobal` or
    `VarKernel` (the HOF); not a callee, not a let RHS, not stored in a record/list/tuple;
  - it is CLOSED: the free-local set of `L` (below) is empty after removing `L`'s own params;
  - the enclosing node is `Define`/`TrackedDefine` (not `Cycle`, not a port; `TailDef` bodies
    excluded — their labels are local);
  - `L`'s body does not mention `VarCycle` (a cycle member referenced from a lifted global would
    need the cycle's placeholder machinery).

Capturing lambdas are OUT: lifting them turns captures into parameters and changes the HOF's
interface.

**Free locals on `TOpt`.** No `freeVars` exists for `TOpt` (`Monomorphize/Closure.elm:196`
`findFreeLocals` is `MonoExpr`-only). Specify `freeLocals : TOpt.Expr MVarId -> Set Name` as a
binders-vs-uses walk over the same constructor set `InlineSimplify.children` enumerates: binders
are `Function`/`TrackedFunction` params, `Let (Def n …)`/`TailDef n args` names, `Destruct
(Destructor n …)`, and `Case label root` (root is a USE, label is neither); uses are
`VarLocal`/`TrackedVarLocal`, `Path.Root n`, `TailCall label args` names, `Case root`. Decider
`Inline` choices are walked. Put it in `PreMono/Fresh.elm`'s sibling `PreMono/Walk.elm` if item 0
creates one; otherwise local to this module and shared later.

### 3.2 The new node

`TOpt.Define L deps { tipe = L's meta.tipe, tvar = Nothing }` inserted into the graph's nodes
`Dict` under

```
Global home ("<parent>$lift" ++ String.fromInt n)
```

  - `home` = the ENCLOSING definition's `Global home _`. NOT `Rewriter.wrapperHome`
    (`Staging/Rewriter.elm:53`, `("eco","internal") "GlobalOpt"`): AbiCloning treats a
    `wrapperHome` lambdaId as a BLOCKER (`isWrapperHome`, `:680`, → `blocked = True`), which
    is the opposite of what we want.
  - `$` is illegal in Elm identifiers, so no user global can collide; the MLIR symbol is
    `sanitizeName`'d (`Generate/MLIR/Names.elm:25-45`, `$` → `_dollar_`), and spec symbols
    already carry `_$_`, so the emitter is proven on the character. `n` is a per-parent counter
    in node-walk order — deterministic, and stable across `rounds` because the pass runs ONCE
    (it is not part of the inliner's fixpoint; a second run would see `VarGlobal`s, not lambdas).
  - `deps` = every `Global` referenced in `L` (walk `VarGlobal`/`VarEnum`/`VarBox`/`VarCycle`,
    `EverySet.insert TOpt.toComparableGlobal`, `Data/Set.elm:68`). Consumers of `deps`:
    `AssignMVarIds.elm:528` and `Specialize.elm:1621` forward it; `InlineSimplify.elm:856-859`
    uses it for the recursion SCC. The mono ENGINE does not read it. Exactness matters for the
    SCC guard: a lifted `\x -> f x` where `f` is the parent makes `f ↔ lifted` a 2-cycle in deps
    (not a `Cycle` NODE), which correctly makes both non-candidates for the inliner. Also add
    `lifted` to the PARENT's `deps` (it now references it) — `Module.elm:236` is the precedent for
    building a synthetic `Define` with a deps set.
  - `AnnotationsByGlobal` entry: `Can.Forall <binders> L.meta.tipe` where binders = the free
    `MVarId`s of `L.meta.tipe` (after item 0 these are the enclosing definition's own scheme
    ids; a closed lambda in a caller polymorphic in `a` has a type mentioning `a`, and the lifted
    global's scheme must quantify it so mono keys a spec per instantiation). Mono tolerates
    absence (§2), but `InlineSimplify`'s item-5 `callerBinders` reads the annotation of the
    ENCLOSING global — for the lifted global's own body the annotation is what makes its
    variables "caller binders". `schemeRoots`: no entry (plain `ensureMVarId` path; the ids are
    already assigned). `fields`, `varSupers`: untouched.

### 3.3 The replacement reference

`TOpt.VarGlobal region (Global home lifted) L.meta` — the LAMBDA's meta, verbatim. Every other
`VarGlobal`'s meta is the referenced global's scheme instantiated in the caller's environment;
here the "scheme" IS the caller's own variables (the lambda was born in this scope), so the
verbatim meta is exactly the correct instantiation. `classifyRef` (`Translate.elm:~ 620`) loads
that type, injects the `g|` identity, and enqueues the spec keyed on the zonked mono type — the
same demand the lambda literal produced. Do NOT `freshenCopy` it (that would sever the
caller-binder identity) and do not `mintNewNode` it (its arrows already carry ids from item 0).

### 3.4 Ids and the Fresh discipline

The lambda MOVES: its `SrcLambdaId` and every `ArrowId` in its metas stay valid and unchanged.
Nothing new carries a `TLambda` with `NoArrow` — the `Define`'s meta and the reference's meta are
`L.meta` verbatim — so `mintNewNode` has nothing to assign; call `assertMinted` in tests
(`mono.validate`) to prove it. This item introduces NO shared id: the lambda node exists once,
in its new home.

### 3.5 Pipeline, flag, report

  - `Compiler/GlobalOpt/PreMono/LiftClosedArgs.elm` exposing `run : Config.InlineConfig ->
    GlobalMVarState -> TOpt.GlobalGraph MVarId -> ( TOpt.GlobalGraph MVarId, GlobalMVarState,
    Metrics )` (state threaded unchanged — this pass mints nothing).
  - Hook: `Builder/Generate.elm:runMonoOptPipeline`, after `EtaExpand`, before
    `InlineSimplify.optimize` (`:749` today); report line via the `preInlineReport` Task shape
    (`:754-764`), `renderPreLiftReport`.
  - Flag `inline.liftClosedArgs : Bool`, default `False`: `Compiler/Eco/Config.elm` field
    (pattern `:998`), default (`:1091`), decoder `D.optionalField "liftClosedArgs"` (`:1207`),
    hash token `lift=` (form at `:1452`); `Builder/Eco/Config.elm`
    `applyInlineLiftClosedArgsOverride` copying `applyInlinePreMonoOverride` (`:1793-1815`,
    record UPDATE via the `inline` binding), env `ECO_INLINE_LIFT_CLOSED_ARGS` read next to
    `:367`.
  - Report: `pre-lift: candidates= closed= capturing= lifted= declined{cycle,tailDef,varCycle}=`
    plus a top-parent list, on stderr when `inline.report`.

## 4. Adversarial review

**R1 — loopify defeat (the biggest risk).** After the lift, `tryLoopify` sees a `MonoVarGlobal`
argument and does not fire, so the HOF's loop body is not inlined at the call site. Today the
self-compile loopifies 1,111 of 2,252 candidate sites. A lifted argument trades "local loop +
possibly a residual generic apply on the re-synthesized callback" for "keyed HOF spec with a
direct `eco.call`". Which wins is per-site heat. RESOLUTION: (i) v1 restricts to HOF callees that
are NOT loopifiable — `buildLoopifiables` (`:1789`) admits only `MonoTailFunc` specs with a
function param that `paramLoopifiable` accepts, so the pre-mono predicate approximates it as
"callee global is recursive (item 4's/InlineSimplify's `recursiveGlobals` SCC) AND has a
function-typed param" → SKIP those; (ii) `loopified=` in the post-mono census is a HARD gate: it
must not drop with the flag on. If the residual generic apply inside loopified bodies is itself
heavy, that is a LOOPIFY fix (stamp the substituted closure's member — item 2's family), not a
reason to lift.

**R2 — origin of the 1,439.** Unmeasured split between loopify artifacts, `wrapperHome`
blockers and genuine unindexed `l|` members. RESOLUTION: §5 census, three-way, BEFORE any code
in §3 is written. Expectation set by §1.2: the genuine class may be small.

**R3 — the new global's scheme.** A closed lambda in a polymorphic caller has caller-binder
`MVarId`s in its type. If the annotation binders are wrong, mono keys one spec for two
instantiations. RESOLUTION: binders = free `MVarId`s of `L.meta.tipe` (§3.2); unit test pins
them; `PreMonoInlineTest`-style E2E with the lifted global used at two types.

**R4 — does mono treat a global that is only ever REFERENCED correctly without an annotation?**
Yes: `translateVarRef`/`classifyRef` never consult annotations; only call-by-name does (§2). But
the item-5 `callerBinders` relaxation reads the enclosing global's annotation, so the lifted
global gets one anyway.

**R5 — CafHoist (CGEN_069) and CafDedupe.** CafHoist hoists maximal CLOSED subexpressions of
function bodies into CAFs post-mono; a lifted global is a function (has params), not a CAF value,
so it is not a hoist target — but its BODY's closed subexpressions still are, exactly as before
the lift. CafDedupe may merge two lifted specs with structurally identical `(body, type)` — that
is a win, and FORBID_OPT_003 is respected by construction (identical layouts). RESOLUTION: no
change; `cafHoist`/`cafDedupe` counters recorded in the census run.

**R6 — LSS_031/LSS_038 on the moved lambda.** The lifted `Define`'s closure is now emitted UNDER
THE SPEC's name (`collectNode`, `:326`, `Just specId`) and indexed as the spec's own function;
its member key becomes `g|`, which AbiCloning resolves via `g2global` BEFORE the index is
consulted (memory `noinstance-r1-r3-measured`). LSS_038's instance ordinal qualification applies
to lambda instances inside specs; a top-level function is ordinal 0 — never tagged. RESOLUTION:
no invariant change; `stampedPapGlobal`/`dispatchUpgraded` must not regress in the two-arm run.

**R7 — the inliner running after this pass.** The lifted global is a `Function` with params and
small cost, so it is a CANDIDATE — but candidates are inlined only at `Call` sites, and its only
occurrence is in ARGUMENT position. It will not be inlined back. RESOLUTION: assert in the unit
test (`inlinedByCallee` has no `$lift` entry).

**R8 — name stability and collisions.** `$` cannot appear in user identifiers; the counter is
per parent in deterministic walk order; the pass runs once. RESOLUTION: byte-identity at defaults
(flag off) and an `assertMinted`-style uniqueness check on node keys in the unit test.

**R9 — `Debug.log`/crash ordering.** The lambda's body executes at the same points as before
(it is applied by the HOF either way); only its closure ALLOCATION disappears. No semantic move.

## 5. Census — RUN FIRST, three layers

All behind `inline.report` / `lss.report`; zero cost off.

| layer | where | fields | purpose |
|---|---|---|---|
| A. post-mono origin split | `AbiCloning` `g1absent…` decline (`:2349`/`:1662`): join member `m` to its INSTANCES' `lambdaId` homes via a one-shot graph scan of `MonoClosure` nodes keyed by `lssMember`/`srcLambda` (the same walk as `collectInstances` but keeping ALL closures, indexed or not) | `g1absentl.origin{loopify,wrapper,genuine,none}` — `loopify` = any instance whose lambdaId name starts `mono_inline_`, `wrapper` = `isWrapperHome`, `none` = no closure anywhere carries the member | which of the 1,439 are this item's at all |
| B. closed/capturing | same scan: `List.isEmpty closureInfo.captures` per genuine instance | `g1absentl.genuine.closed=` / `.capturing=` | v1 scope size |
| C. pre-mono candidates | `LiftClosedArgs` with `liftClosedArgs=0`, report on: the §3.1 walk without rewriting | `pre-lift: candidates= closed= capturing= loopifiableCallee=` | what the pass would touch, and how much R1 removes |
| D. dispatch weight | uprobe on the closed-genuine sites' HOST specs (memory: bpftrace return-address method, `sudo -n`, `mount -t tracefs`, `BPFTRACE_MAP_KEYS_MAX`) | dispatches attributed to those sites | the number that decides |

**Build gate:** layer B `closed` ≥ 100 sites AND layer D ≥ 1 % of generic dispatch. Below either,
CLOSE UNBUILT and record the split in the parent plan. This arc has mispredicted from site counts
four times; §1.2 is the fifth warning.

## 6. Lowered steps

| # | change | files | gate |
|---|---|---|---|
| 1 | Census layers A–C (report-gated) | `AbiCloning.elm` (decline arm + one-shot closure scan), new `PreMono/LiftClosedArgs.elm` walk-only mode, `Generate.elm` report line | flag-off byte-identical; census lines on the self-compile in both arms |
| 2 | Layer D dispatch attribution | benchmark scripts only | numbers recorded here; STOP if the §5 gate fails |
| 3 | Flag + plumbing | `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm` | hash token present; env round-trips; byte-identical at defaults |
| 4 | `freeLocals` + scope predicate + rewrite (§3.1–3.3), R1 loopifiable-callee exclusion | `PreMono/LiftClosedArgs.elm`, `Generate.elm` hook | unit tests §7; `assertMinted` clean under `mono.validate` |
| 5 | Gates | — | byte-identical defaults + fixed point; E2E 887/889 both arms with flag on; `ECO_INLINE_THRESHOLD=0` leg; smoke fixtures |
| 6 | Measure | `benchmarks/lss-opt.md` Run | two-arm protocol + dispatch uprobe; `loopified=`, `singleton_fast`, `stampedPapGlobal` must not regress |

## 7. Tests

  - `TestLogic/GlobalOpt/LiftClosedArgsTest.elm` (harness `runToAssigned` from item 0):
    node count +1 per lifted lambda; the new global's `deps` exact; annotation binders exact for
    a polymorphic caller; a CAPTURING lambda not lifted; a lambda inside a `Cycle` not lifted; a
    lambda whose callee is loopifiable (recursive HOF with function param) not lifted (R1); the
    inliner's `inlinedByCallee` has no `$lift` key after `InlineSimplify` (R7); node keys unique.
  - `test/elm/src/LiftClosedArgTest.elm`: the `LiftLam` shape with `-- CHECK: r: 3` plus a
    second HOF whose callee is NOT loopifiable (a non-recursive `applyTwice`) and a
    caller-polymorphic use at two types; run in both arms with the flag on.
  - The existing `PreMonoInlineTest`, `RecordNarrow01/06`, `LetNumberFoldr/ApplyTo`,
    `PapFastStampTest` smoke.

## 8. Measurement

Per `benchmarks/lss-opt.md`: one cold run per arm, census off, no probe; dispatch by a separate
uprobe run; record `loopified=` and the LSS `globalopt` counters in the entry. Judge on dispatch
at the lifted sites' host specs (layer D before/after), not on site counts.

## 9. Risks

  - The item's premise on the probed shape is loopify defeat, not repair (§1.2). If layer A says
    most of the 1,439 are `loopify`-origin, the right fix is in the post-mono pass (stamp the
    substituted closure's member), and this plan closes unbuilt.
  - Lifting removes the closure allocation but adds a top-level spec per (lambda, instantiation);
    `maxSpecsPerGlobal` bounds it; `.mlir` size is recorded.
  - A lifted global referenced from a `Cycle`-member parent: excluded in v1 (§3.1).

## 10. What not to do

  - Do not lift capturing lambdas by turning captures into parameters — it changes the HOF's
    interface and is a different (defunctionalization-shaped) transform.
  - Do not use `wrapperHome` for the new global (`:680` blocks it).
  - Do not `freshenCopy` the reference meta (§3.3) — it severs caller-binder identity.
  - Do not build before §5; do not read the 1,439 as weight.

## 11. §5 census — RUN 2026-09-12. Verdict: **CLOSE UNBUILT**

Run on the current tree (η, `preMono`, `preserveSets` all default-on; `out.mlir` 15,449,374 B, the
Run-8 fixed point). Self-compile throughout, `eco-psetsDefA`, `ECO_MONO_LSS_REPORT=1
ECO_MONO_LSS_CENSUS=1`. Raw: `build/compiler/build-kernel/la-{def,loop0,post0}.stderr`,
`lc-def.stderr`, `$SP/lD-bt.txt`.

### 11.1 Layer A — origin of the `g1absentl` declines

The plan's layer-A design (join member ids to un-indexed closure instances) is UNRUNNABLE and its
premise was wrong: `postSettleTarget`'s `Nothing` arm is reached only when the member is absent from
`collectInstances`' index entirely, and `collectClosure` inserts an entry for every closure whose
`instanceMember` resolves — wrapper-home and adopted ones included, as `blocked = True`. So a
`g1absentl` member has NO closure carrying it anywhere in the graph, and there is nothing to join to.
`wrapper` is not a possible origin (those decline as `declinedBlocked`), and `genuine` vs `loopify`
cannot be told apart by scanning instances that do not exist.

Three arms of the SAME binary answer it directly instead:

| arm | `g1absentl` | `declinedNoInstance` | `dispatchUpgraded` | out.mlir (B) |
|---|---:|---:|---:|---:|
| defaults | **1,758** | 14,609 | 18,088 | 15,449,374 |
| `ECO_INLINE_LOOPIFY=0` | **612** | 13,473 | 19,264 | 15,284,193 |
| `ECO_INLINE_POST_MONO=0` | **0** | 31,488 | 19,153 | 14,251,245 |

**Every one of the 1,758 is manufactured by the post-mono inliner.** 1,146 (65.2 %) by `loopify`
alone, and the loopify delta is exactly the three loopified callees, to the site: `List.foldl`
−1,063, `List.any` −78, `List.Extra.find` −4, with all 21 other hosts unchanged. The remaining 612
are the pass's other reshapes.

`g1absentl = 0` is not a workload collapse: at `postMono=0` the noInstance population more than
DOUBLES (14,609 → 31,488, `g1kernel` 719 → 23,179), `g1absentp` is flat at ~600, and MORE sites
stamp (19,153 vs 18,088). Lambda members resolve when nothing reshapes their closures.

**§1.2's probe generalises: the class this item exists to repair is empty.** `genuine = 0`, so
layer B is 0 and the §5 build gate (`closed ≥ 100` genuine sites) fails outright.

### 11.2 Layer C — the pre-mono population (`pre-lift-census:`)

`Compiler/GlobalOpt/PreMono/LiftClosedArgs.elm` is BUILT and RETAINED as a census: `census` runs the
§3.1 predicate and returns metrics only, rendered by `Generate.renderPreLiftReport` behind
`inline.report`. Emission is unaffected — the census-on run reproduced the census-off build BYTE FOR
BYTE (15,484,502 B). Unit suite 13,506/12 (the pre-existing POST_010 accessor failures).

```
pre-lift-census: candidates=5341 closed=2044 capturing=3297 liftable=1039
  declined.cycle=523 declined.port=0 declined.tailDef=171 declined.varCycle=0
  declined.loopifiableCallee=311 lambdasSeen=12965 callsSeen=72871
```

Read it carefully: 1,039 lambdas COULD be lifted, and not one of them is a `g1absentl`. Layer C
counts a source shape; layer B counted a failure. R1 is not the binding constraint either — it
removes 311, less than a third of what the scope rules already remove.

Two corrections the implementation forced, both measured:

  - **R1's recursion test must include a `TailCall`.** A self-tail-recursive definition is rewritten
    into a `TailDef` loop before this point, so `List.foldl` names neither itself nor anything in
    its own SCC. With only `InlineSimplify.recursiveGlobals`' three tests, `declinedLoopifiable` is
    **0** and `List.foldl`/`Dict.foldr` read as liftable.
  - **Cycle MEMBERS must be keyed individually.** A `Cycle` node's own global is never a callee;
    call sites name `Global home memberName`, exactly as `EtaExpand.buildIndex` keys them. Without
    that, every mutually recursive HOF misses both R1 predicates.

### 11.3 Layer D — dispatch weight, caller-attributed

Uprobe on `eco_apply_closure_eval`, return address at `[rsp]` → calling spec (the 2026-09-05 method).
838,532,078 generic-funnel entries over 4,200 distinct callers, probed wall 14:53.

| g1absentl host | sites | generic dispatch INSIDE its specs | share |
|---|---:|---:|---:|
| `System.TypeCheck.IO.andThen` | 134 | 140,754,783 | 16.79 % |
| `System.TypeCheck.IO.map` | 53 | 68,465,269 | 8.16 % |
| `List.foldl` | 1,063 | 5,493,967 | 0.66 % |
| `List.any` | 78 | 474,450 | 0.06 % |
| `Result.andThen`, `Maybe.map`, `Maybe.andThen`, `Builder.Eco.Config.updateLss`, … | 353 | ~29 | 0.00 % |

**Site count is inversely ranked to weight for the fifth time in this arc.** `List.foldl` hosts 60 %
of the sites and 0.66 % of the dispatch; the two IO-monad hosts are 10.6 % of the sites and 24.95 %.
Confirmed independently on the callee side (Run 8's `[dispatch-stats]` `fp` rows symbolized): ZERO
generic dispatch reaches a `_tail_mono_inline_*` symbol, so loopify's rebuilt closures are cold — the
loop really does absorb the callback, and its residual apply is the plan's one-per-site, not a hot
path. 56.31 % of generic dispatch lands on lambda bodies overall (441,429,579 of 783,918,852).

### 11.4 Verdict and successor

CLOSE UNBUILT, on §9's first risk exactly as written. The lift cannot repair `g1absentl` because
nothing needs repairing before `MonoInlineSimplify` runs and the lift runs before it. §10's "do not
read the 1,439 as weight" was right twice over: they are not weight, and they are not this item's.

The live question the census leaves behind belongs to item 2's family, not here: the post-mono
inliner still clears 612 non-loopify lambda members after `preserveSets` retired the `tryInlineCall`
partial arm, and they sit in `IO.andThen`/`IO.map`, which host a quarter of all generic dispatch.
Price THAT at the site level before building anything: a host's dispatch is an upper bound, since a
hot spec has generic sites that are not these.

## 12. The 612 — what they are, priced (2026-09-13)

§11.4 asked for the non-loopify residue to be priced at site level before anything is built. Done.
Arms of `eco-psetsDefA`, all with `ECO_INLINE_LOOPIFY=0` so the 1,146 loopify-made sites are already
gone; shape census from `bin/eco-shape` (`instQual.absentL`); dispatch from a same-tree fixed-point
uprobe run (`[G] FIXED POINT`, so the per-spec join is valid).

### 12.1 They are 607 distinct lambdas, each declining once

`sites=612 distinctMembers=607`, top members 3/2/2/2/1/1/… This is not a handful of hot lambdas
consulted repeatedly. It is one member per continuation.

**Callee shape is `local` at every single site** — 478 applied to ONE argument, 134 to TWO. Never
`closureLiteral`, never `global`, never `callResult`. The spec is dispatching on a parameter, which
is the ordinary HOF shape; the 134 two-argument sites are exactly `IO.andThen`'s 134, i.e. the
η-expanded `f a s` continuation call.

### 12.2 They are made by the HOF-admitted inline class, and `beta` is the consuming step

Identity is never stripped: `preserveSets` retired the only reshape that cleared a member and the
census confirms `cleared=0 bySite=` on the self-compile. The closure is CONSUMED instead.

| arm (all `loopify=0`) | `g1absentl` | `inlined` | `beta` |
|---|---:|---:|---:|
| base | 612 | — | — |
| `ECO_INLINE_HOF_THRESHOLD=0` | **1** | 43,766 | 148 |
| `ECO_INLINE_THRESHOLD=0` | 595 | 12,210 | 789 |
| both 0 | 1 | 10,058 | 148 |
| `ECO_INLINE_PRESERVE_SETS=0` | 612 | 48,982 | 1,023 |
| `ECO_INLINE_FIXPOINT_ITERATIONS=1` | 612 | — | — |

`hofThreshold` alone accounts for all of them while leaving 43,766 inlines in place; the general
small-candidate class accounts for none. It is not the fixpoint (one round suffices) and not
`preserveSets` (identical either way — the 1,756 declines are a coincidence of magnitude, not a
cause). `beta` tracks the population 1:1 across every arm: 148 wherever `g1absentl` is 1.

### 12.3 Only 187 of the 612 ever execute

Per-spec join, same tree, same compile:

| host | declining sites | live specs | live generic sites | generic dispatch | share |
|---|---:|---:|---:|---:|---:|
| `System.TypeCheck.IO.andThen` | 134 | 90 | 133 | 140,793,140 | 16.79 % |
| `System.TypeCheck.IO.map` | 53 | 31 | 32 | 71,525,270 | 8.53 % |
| `Result.andThen` | 154 | 0 | 0 | 0 | 0.00 % |
| `Maybe.map` | 87 | 1 | 1 | 29 | 0.00 % |
| `Maybe.andThen` | 35 | 0 | 0 | 0 | 0.00 % |
| `Builder.Eco.Config.updateLss` | 65 | 0 | 0 | 0 | 0.00 % |
| `EtaExpand.bump`, `MapTemplate.bump`, 12 more | 84 | 0 | 0 | 0 | 0.00 % |

**134 declining sites against 133 live generic sites is one declining site per live site**: in
`IO.andThen` the declining site IS the hot dispatch. Together the two IO hosts are 212,318,410
generic dispatches, **25.31 %** of the self-compile's total, at 187 sites. The other 425 sites never
execute.

So the target is 187 sites carrying a quarter of all generic dispatch, not 612 and not 1,758. The
repair has to keep a member's instance alive across a HOF-admitted inline whose `beta` consumes the
closure — post-mono, in `MonoInlineSimplify`, which is where every one of these is made.

### 12.4 CORRECTION (2026-09-13, later): the 612 sites are in DEAD specs

§12.3's "one declining site per live site" was a coincidence of counts, not a join. A per-site
trace (`instQual.absentL` `T|<host>|<spec>|<member>|<outcome>` rows, both arms of one tree,
`k-loop0` vs `k-post0`) and a reference count over the emitted text settle it:

  - **Same member at every site in both arms** (612 same, 0 different): the inliner does not rewrite
    annotations. With the inliner off those exact sites STAMP (682 `stamp`, 17 `bodyMismatch`).
  - **All 583 specs hosting the 612 sites are UNREFERENCED in the inliner-on artifact** — no direct
    call, no PAP construction, nothing — and every one of them is referenced with the inliner off.
    `Result.andThen` 154/154, `IO.andThen` 134/134, `Maybe.map` 87/87, `updateLss` 65/65,
    `IO.map` 53/53, `Maybe.andThen` 35/35, the `bump`s 19/19 and 17/17.

**Mechanism, verified end to end.** η-expansion (plan 01) saturates the monad-bind call sites, which
makes `andThen`/`map`/`Result.andThen`/`Maybe.map` inline candidates under the H2 "called-param"
budget (`hofThreshold`; the pass's own doc: "inlining them lets a lambda argument beta-reduce away
at the call site"). Their single caller is inlined, the callback literal is `ForwardClosure`-forwarded
into the copied body and beta-reduced — the call is now DIRECT, strictly better than a stamp. The
keyed spec the caller used to reach is left in the graph with no reference: nothing prunes dead
specs after `MonoInlineSimplify` (the `Prune` pass is mono-time), so `AbiCloning` still walks it,
its `f a s1` site still names the callback's member, the member's only instance was the closure
that was just beta'd away, and the census records `g1absentl`. The decline is real; the site is
dead. (No live `_tail_mono_inline_*` dispatch, no in-place identity strip — every one of those
hypotheses was tested and failed.)

**Consequences.**
  - The "25.31 % of generic dispatch at 187 sites" in §12.3 is WRONG as an attribution. The two IO
    hosts do carry a quarter of generic dispatch, but in OTHER specs — the 28-builder,
    28-instance ones (e.g. `IO.andThen_$_19330`, 68.8 M generic entries, `bodyMismatch` in both
    arms). The g1absentl sites carry nothing.
  - There is nothing to keep alive: the closure was consumed on purpose and its consumer is direct.
    The only defect is dead code in the artifact and in the census. The cheap fix is a
    reachability prune after the post-mono inliner (or before AbiCloning); it removes the 1,758
    `g1absentl` from the census and the dead specs from `out.mlir`.
  - The measurement instruments (`absentL` `K|`/`R|`/`I|`/`T|` rows, the `I|` render capped at
    6,000 rows — RAISE IT before relying on it, member ids above ~2xxxx are cut) are retained.

**Size of the dead code (2026-09-13, `k-loop0`/`k-post0` text artifacts).** Unreferenced
code-bearing functions (a body with a call, apply, case or loop; constructor/layout descriptors
excluded): **6,608 with the inliner on, 4,508,040 B (4.86 % of the text artifact), vs 921 / 1.27 %
with it off.** The delta is the inliner's leftovers: `Task.andThen` 1,116, `List.foldr` 917,
`Task.map` 408, `Task.succeed` 290, `Elm.JsArray.foldl` 177 — the same "called-param" inlines. The
583 `g1absentl` specs are a tenth of it. A post-inline reachability prune is worth building on the
artifact-size ground alone, and it removes 1,758 census declines for free.

**Successor:** `plans/post-inline-dead-spec-prune.md` — a reachability prune immediately after
`MonoInlineSimplify`, reusing `Prune`'s core with edges re-collected from the rewritten bodies.

**RESOLVED 2026-09-13.** `plans/post-inline-dead-spec-prune.md` shipped default-on and
`g1absentl` measures **ZERO** on the self-compile (1,781 with `ECO_INLINE_PRUNE_DEAD=0`). Every
decline this plan chased — the 612 of §12, the 1,146 loopify-made ones, all of it — was a call
site in a specialization nothing reaches. Not one was a missed optimization, and the artifact lost
13.94 % with dispatch unmoved.

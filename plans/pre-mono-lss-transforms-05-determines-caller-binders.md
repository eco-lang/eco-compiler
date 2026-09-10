# Pre-mono LSS transforms — 05: `determines` accepts caller-binder bindings

**Status:** IMPLEMENTATION-READY (2026-09-10). Item 5 of `plans/pre-mono-lss-transforms.md`.
Assumes item 0 (`AssignMVarIds` before the inliner; `TOpt.Expr TypeIds.MVarId`; `Fresh.freshenCopy`)
has landed. §8 says what changes if it is built on the `Name`-typed tree instead.

**Origin:** `/work/pre-mono-transformation.md` §1.2–§1.3 (R1, R2) and
`scratchpad/q1-premono-completeness.md` §1–§2. All counts below are from the EARLY-arm
(`preMono=1 postMono=0`) self-compile on `eco-q1b` unless marked INFERRED.

**Baseline this plan is written against:** the `eco-q1b` source — `InlineSimplify.elm` WITH the
§16 `TAlias` fix (`typeVarsOfType` folds only an alias's ARGUMENT variables; `matchType` matches
same-name aliases argument-wise, else `expandAlias` then matches) and WITH Q1's report-gated census
(`undCallerPoly`, `undLocal`, `undBodyOnly`, `undLeak`, and `censusUndetermined`'s per-site
classifier, which already threads the caller's binders from `AnnotationsByGlobal` through
`rewriteGraph` into `Ctx`). Both were gated (E2E 887/889 EARLY, fixed point byte-identical) and are
the baseline of **1,865 inlines / 864 undetermined**. Line numbers cited as `:NNN` below are from
the §12-state file where a function is unchanged by §16/Q1; functions that §16/Q1 changed are cited
by name — re-verify lines against the tree when implementing.

## 1. Problem

After the alias fix, the EARLY arm performs **1,865** inlines and declines **864** calls as
`undetermined` — the call site does not bind every callee type variable to a GROUND type. Of the 864
(Q1 §1, MEASURED):

| class | sites | top callees | what it is |
|---|---:|---|---|
| **caller-polymorphic** | **520** | `Utils.Crash.crash` 64, `Array.length` 60, `List.take` 40, `Parser.Advanced.skip` 32, `Task.Extra.io` 28, `Parser.Advanced.ignorer` 28, `Url.Parser.State` 28, `Dict.isEmpty` 24, `List.isEmpty` 20, `Tuple.second` 20 | the callee's variable is bound to a type whose only free variables are BINDERS OF THE CALLER's own scheme (`Array a -> Int` called inside a function polymorphic in `a`) |
| unsolved local | 188 | `Maybe.withDefault` 96, `Tuple.second` 44 | an un-annotated let / lambda parameter whose type only `MonoSolver` decides |
| body-only | 156 | `String.isEmpty` 124 | a variable the call site is never asked about — 148 in callees with zero annotation binders; Q1 established these are OPERATOR-REFERENCE metas, not a solver leak |

`determines` (`InlineSimplify.elm:1510-1521`) requires `isGroundType t` (`:1524`) for every callee
variable. The 520 are sound to inline and refused only because "ground" is stricter than "known to
the caller". Net recoverable: 520 − 68 bottom-shaped = **≈ +450 inlines (+24 %)**, plus R2's ≈ +150.

## 2. Design

### 2.1 The relaxation

```elm
determines : Ctx -> Candidate -> Subst -> Bool
determines ctx cand subst =
    List.all
        (\v ->
            case CoreDict.get v subst of
                Just t ->
                    isGroundType t
                        || (ctx.callerBinders /= Nothing && boundOnlyByCaller ctx t)
                Nothing ->
                    False
        )
        cand.typeVars

boundOnlyByCaller ctx t =
    -- every free MVarId of t is a binder of the enclosing definition
    CoreDict.foldl (\v _ ok -> ok && Set.member v binders) True (typeVarsOfType t CoreDict.empty)
```

`ctx.callerBinders : Maybe (Set String)` (keys `Id.toComparable mvarId`) is `Nothing` when the flag
is off or the enclosing node has no usable annotation, so the flag-off path is byte-identical.

### 2.2 Where the caller's binders come from

`rewriteGraph` (`:1101-1117`) folds `nodes` per `Global` and has the `annotations` field
(`AnnotationsByGlobal`) in hand but does not use it. Per node:

```elm
callerBinders g =
    case Dict.get TOpt.toComparableGlobal g annotations of
        Just (Can.Forall _ tipe) -> Just (Set.fromList (CoreDict.keys (typeVarsOfType tipe CoreDict.empty)))
        Nothing -> Nothing
```

**Why the binder set is read off the annotation's TYPE and not its `FreeVars`.** `Can.Annotation id =
Forall FreeVars (Type id)` with `FreeVars = Dict Name ()` (`Canonical.elm:285-292`) — the binder set
is `Name`-keyed and is NOT parameterised by `id`. After item 0 the type carries `MVarId`s while
`freeVars` still carries names, so the ids must be collected from the type. That is exact: a
top-level annotation type's free variables ARE its binders (`rewriteAnnotation`,
`AssignMVarIds.elm:451-479`, pre-seeds `ensureBinder name` for every `freeVars` name and then
rewrites `tipe` in that env, so the two agree by construction). Before item 0 the same function on
`Can.Type Name` yields the names, i.e. `freeVars`' keys.

Threading: Q1's census ALREADY does this — `rewriteGraph` looks the enclosing global's annotation
up in `annotations` and passes the binder set to `censusUndetermined` to classify a decline as
`undCallerPoly` vs `undLocal`. Step 2 promotes that census-only plumbing into `Ctx.callerBinders`
(set before `rewriteNode c node`, restored after) so `determines` reads the same set the census
classifies by — the counter and the guard cannot then disagree. `Cycle` nodes are not rewritten by
the inliner at all (`rewriteNode`'s `_` arm), so a per-node set is sufficient; a per-inner-
definition set for cycles is v2 and moot today.

### 2.3 Why VERBATIM substitution is sound (no re-mint)

Inside the copy, a bound type `t` whose free ids are caller binders is spliced in as-is by
`freshenCopy` (item 0: `Subst` entries are substituted, and ONLY ids absent from `Subst` are
re-minted). Every occurrence of the caller's `a` in the caller's body — including inside the splice
— is then the SAME `MVarId`, because `rewriteNodes` (`AssignMVarIds.elm:488-522`) gives each
top-level node ONE `SchemeEnv` and `ensureBinder` (`:395-402`) returns the same id for the same
name (root-backed via `schemeRootsForDef` or plain via `ensureMVarId`). Monomorphization
instantiates the caller once per demand and every occurrence of that id follows.

The `let p = arg` wrappers `doInline` builds (`:1529-1560`) carry the substituted parameter type as
their declared type. That is today's un-annotated-let shape: `translateLet` (`Translate.elm:5676+`)
computes `useBodyType = Mono.containsAnyMVar defMonoType0 || …` and defers to the RHS's type
whenever the declared type still has an MVar, so a declared type mentioning the caller's `a` is
handled exactly as `let x = f y` is handled today.

**Contract with item 0's `Fresh`:** `freshenCopy subst state body` must never re-mint an id that
appears free in a `Subst` VALUE. Item 0 must state this in `Fresh.elm`'s doc; this plan's R1 test
pins it.

### 2.4 The exclusion: bottom-shaped callees

`crash : String -> a` (`compiler/src/Utils/Crash.elm:20-22`, body `Eco.Crash.crash str`;
`eco-kernel-cpp/src/Eco/Crash.elm:16-18`, body `Eco.Kernel.Crash.crash str`). `Eco.Crash.crash` is
refused by `polyKernel` (`:439-451`: a `VarKernel` whose meta type still has a variable).
`Utils.Crash.crash` is NOT — its body is a `Call` of a GLOBAL, no `VarKernel` node — so it is a
candidate today and is declined per call as caller-polymorphic 64 times. With 2.1 it would inline,
and each caller specialized at two result kinds would contain the kernel call at two ABIs after
item 4 forwards the alias — plan `pre-mono-inline-simplify.md` §15.3's
`Kernel signature mismatch for Eco_Kernel_Crash_crash: existing (eco.value -> eco.value) vs new
(eco.value -> i16)`.

**Predicate (candidate-level, syntactic):**

```elm
bottomShaped : List ( Name, Can.Type id ) -> TOpt.Expr id -> Bool
bottomShaped params body =
    case TOpt.typeOf body of
        Can.TVar r -> not (List.any (\( _, t ) -> CoreDict.member r (typeVarsOfType t CoreDict.empty)) params)
        _ -> False
```

A result that is a bare variable occurring in no parameter type can only be produced by ⊥ (a
crash, an infinite loop, or a kernel escape). Placed in `buildCandidates`' guard chain
(`:259-330`) after `polyKernel`, with its own counter `bottomShaped`. The general hazard behind it —
a kernel call in the copy whose RESULT type mentions a substituted caller binder — is what the
predicate proxies; if a non-bottom callee ever trips the ABI conflict, the guard becomes "callee
body contains a `VarKernel` whose result type mentions a caller-bound variable", checked per call.

### 2.5 R2 — ignore reference-node metas in `candidateTypeVars` (step 2)

`candidateTypeVars` (`:655-661`) folds `typeVarsOfExpr` over every node, including
`VarGlobal`/`VarKernel`/`VarCycle`/`VarEnum`/`VarBox` reference nodes whose meta is the REFERENCED
global's scheme instantiated generically (Q1 §1: `isEmpty s = s == ""` is
`call[g:Basics.eq:(?a -> ?a -> Bool)](s:String, "") : Bool`; the call and args are ground, the
operator reference is not). Those variables are never asked about at the call site, so every such
candidate is `undetermined` with `undBodyOnly`. Fix: `typeVarsOfExpr` skips the meta of the five
reference constructors (recursing into nothing — they have no children). Sound because
`translateVarRef` (`Translate.elm:601-613`) already receives the generic reference type for the
un-inlined body and resolves it by demand; the copy is the same shape. Recovers ≈150 (148
`undLeak` + part of body-only). Must keep the reference metas OUT of `polyKernel`'s check too? No —
`hasPolymorphicKernel` inspects `VarKernel` metas deliberately and stays as is.

### 2.6 Step 3 (optional) — per-round re-costing

`rounds` (`:178-208`) re-walks the graph but never re-costs candidates; a callee whose own callees
were inlined in round 1 is cheaper in round 2 (Q1 §3.4). Rebuild the candidate index per round from
the CURRENT graph (`buildCandidates` is already a pure function of the graph). Cost: one candidate
build per round (≤ `fixpointIterations` = 4). Gate: EARLY inline count monotone non-decreasing;
census `roundsRun`.

### 2.7 What stays undetermined by design

- **Unsolved locals (188)** — decided by monomorphization; only `MonoInlineSimplify` reaches them.
- **Binders of an inner let-generalized scheme** (v2) — a polymorphic `let f x = …` inside a
  definition has its own `Forall`; the per-top-level binder set does not include it, so a call inside
  `f`'s body whose types mention `f`'s own binders stays undetermined. Extend `callerBinders` with
  the enclosing `Def`'s scheme when the walk enters a let-generalized binding; needs the inner
  annotation, which `TOpt.Def` does not carry today — hence v2.

## 3. Adversarial review

**R1 — could `freshenCopy` re-mint a caller-binder id?** It must not: a re-minted caller id makes
the copy's occurrence differ from the caller's other occurrences — exactly the collapse-into-one-
variable bug in reverse (two ids where one is needed; the copy then has an unsolved variable and
the §12 layout failures return). Resolution: `Subst` values are spliced verbatim and their free ids
are excluded from re-minting by construction (they are not candidate type vars); the unit pin is
`InlineSimplifyCallerBindersTest.substitutesCallerIdVerbatim`: after `optimize`, every `TVar` id in
the spliced copy that came from the caller equals the caller's id (compare by
`Id.toComparable`).

**R2 — a callee variable bound to a caller binder that is ALSO in a `number`/`comparable`
position.** The `superVar` guard (`:290-297`) is CANDIDATE-level: a callee with a constrained
variable is refused before any call is considered, independent of what the caller binds. Unchanged.
The converse — the CALLER's binder is constrained (Elm annotations may bind `comparable`/`number`;
`varSupers` records them by name and `rewriteAnnotation` seeds them through `ensureBinder`, which
reads `varSupers`) — is fine: the copy carries the caller's constrained id, which mono instantiates
per demand exactly as it does for the caller's own uses. No defaulting decision moves.

**R3 — the `LetNumberFoldrTest` class.** That failure was `number` DEFAULTING keyed on surviving
uses after inlining a HOF. A caller-binder binding introduces no `number` variable of its own (R2),
and `hofParam` (`:284-286`) still refuses HOF candidates. The class is not reopened; the smoke
fixtures `LetNumberFoldr/ApplyTo` remain in the gate.

**R4 — consistency across the CALLER's specializations.** The soundness claim is that two
specializations of the caller instantiate the spliced copy consistently. `PreMonoInlineTest` pins
copies at two types within ONE caller; it must gain a case where a POLYMORPHIC caller containing a
caller-bound inline is itself used at two types (§5).

**R5 — `hofParam`, `rowPoly`, `polyKernel`, `recursiveSkipped` are candidate-level and precede
`determines`; none is affected.** `rowPoly` (open records) stays: `matchType` cannot bind a row
variable, so an open-record binding is never `boundOnlyByCaller` unless the row variable itself is a
caller binder — which is sound (the caller's row is instantiated with the caller).

**R6 — globals without a usable annotation.** `AnnotationsByGlobal` may lack an entry (or carry an
inferred one). `callerBinders = Nothing` ⇒ the relaxation is inert for that caller; no fallback to
"all free vars are binders". Census `noCallerAnnotation` counts them.

**R7 — the guard order.** `bottomShaped` must run BEFORE the candidate is admitted (candidate-level),
not per call: a bottom-shaped callee inlined at a GROUND result type is also wrong (the kernel call
still registers per result kind). So it declines the candidate outright, which also removes the 64
`Utils.Crash.crash` declines from `undetermined` (they stop being calls to a candidate).

## 4. Lowered steps

| step | change | files | gate |
|---|---|---|---|
| 0 | **Verify the baseline is in the tree**: `typeVarsOfType`'s `TAlias` arm folds only the ARGUMENTS' variables; `matchType` has the same-name-alias and `expandAlias` arms; `Metrics` has `undCallerPoly/undLocal/undBodyOnly/undLeak`; `rewriteGraph` threads the caller's binders for `censusUndetermined`. If any is absent the tree is not `eco-q1b`'s and nothing below is measurable | `InlineSimplify.elm`, `Generate.elm:920` (`renderPreInlineReport`) | EARLY census `inlined=1,865 undetermined=864` (520/188/156) to the digit |
| 1 | flag `inline.callerBinders : Bool` default `False`; decoder `D.optionalField "callerBinders"`; hash token `cbind=`; env `ECO_INLINE_CALLER_BINDERS` via `applyInlineCallerBindersOverride` (record update, copy of `applyInlinePreMonoOverride`) | `Compiler/Eco/Config.elm` (`:998` field, `:1091` default, `:1207` decoder, `:1451` hash), `Builder/Eco/Config.elm` (`:367` read, `:1797` setter) | byte-identical defaults; hash token present |
| 2 | `Ctx.callerBinders : Maybe (Set String)`; `rewriteGraph` sets it per node from `annotations` (§2.2), restores after; `determines` takes `Ctx` (§2.1); `tryInline` passes it | `InlineSimplify.elm:114`, `:1101`, `:1440`, `:1510` | flag OFF ⇒ EARLY census unchanged to the digit |
| 3 | `bottomShaped` candidate guard + counter, after `polyKernel` in `buildCandidates`' guard chain (recursive → no params → cost → polyKernel → **bottomShaped** → rowPoly → hofParam → superVar) | `InlineSimplify.elm` `buildCandidates`, `Metrics`, report line | EARLY census `bottomShaped ≥ 1` (`Utils.Crash.crash` is in the compiler's own source) with the flag OFF too — it is candidate-level and unconditional |
| 4 | tests of §5 (unit + `PreMonoInlineTest` extension) | `compiler/tests/TestLogic/GlobalOpt/InlineSimplifyCallerBindersTest.elm`, `test/elm/src/PreMonoInlineTest.elm` | unit green; E2E BOTH arms 887/889 |
| 5 | flag ON census + gates | — | EARLY `undCallerPoly ≤ 10`, `inlined ≈ 2,315` (§6); E2E both arms; `ECO_INLINE_THRESHOLD=0` leg; fixed point |
| 6 | R2: `typeVarsOfExpr` skips reference-node metas (§2.5) | `InlineSimplify.elm:664` | `undBodyOnly ≤ 10`, `inlined ≈ 2,465`; E2E both arms |
| 7 | (optional) per-round re-costing (§2.6) | `InlineSimplify.elm:178` | count monotone; census `roundsRun` |
| 8 | Run-AT-style two-arm protocol run; record in `benchmarks/lss-opt.md` | — | one cold run per arm, census off |

## 5. Tests

**`TestLogic/GlobalOpt/InlineSimplifyCallerBindersTest.elm`** (harness `Pipeline.runToMono`'s
`globalGraph`, assigned via item 0's `runToAssigned`; fixtures via `SourceBuilder` — `tVar`
(`SourceBuilder.elm:720`), `tLambda`, `tType`, `caseExpr`/`pList`/`pAnything`/`boolExpr`; NO
binops — the harness leaves bare TVars on `Binop` nodes, the pre-existing `POST_010` failures):

| test | fixture | pins |
|---|---|---|
| caller-polymorphic call inlined with flag ON | `isEmptyL : List a -> Bool` (case on `[]`); `wrap : List a -> Int`, `wrap xs = if isEmptyL xs then 0 else 1` | `inlineCount = 1`, `undetermined = 0` |
| same call undetermined with flag OFF | same | `inlineCount = 0`, `undetermined = 1`, `undCallerPoly = 1` |
| bottom-shaped candidate refused | `isBottomShaped` exposed and called directly on hand-built `Can.Type` values: `String -> a` ⇒ True; `a -> a` ⇒ False; `List a -> Int` ⇒ False; `( a, b ) -> b` ⇒ False | predicate |
| verbatim ids (R1) | after `optimize` on the first fixture, collect `TVar` ids inside `wrap`'s body; assert the set ⊆ `wrap`'s annotation ids | no re-mint |
| no annotation ⇒ inert (R6) | a fixture whose caller has no annotation entry (strip it from `annotations` before `optimize`) | `undetermined = 1`, `noCallerAnnotation = 1` |
| R2 | `isEmptyS : String -> Bool` via `==` is a BINOP — use `String.isEmpty`-shaped `case String.length s of 0 -> True; _ -> False`? still a call with a generic ref… use the real shape from the self-compile census (`String.isEmpty`) through a probe module compiled with the harness; assert `undBodyOnly` drops to 0 with step 6 | R2 |

**`test/elm/src/PreMonoInlineTest.elm`** (existing; CHECK-based, both arms) gains:

```elm
lenPlus : List a -> Int          -- polymorphic CALLER
lenPlus xs = firstOr 0 [ List.length xs ] + 1   -- inlines `firstOr` at a := Int (ground) AND
                                                 -- `List.length`-shaped helper `count : List a -> Int` at the caller's `a`
-- used at TWO types: lenPlus [ 1, 2 ]  and  lenPlus [ "x" ]
-- CHECK: lenPlusInt: [3, 3, 3]   -- (per input n; fix the arithmetic when writing)
-- CHECK: lenPlusStr: [2, 2, 2]
```

A helper `count : List a -> Int` defined in the module (case-based, no binop) is the caller-bound
callee; the pin is that `lenPlus`'s two specializations both give correct answers (R4). Expected
values are computed by hand and verified against the flag-OFF arm before the flag-ON arm is trusted.

## 6. Census and measurement

`pre-inline-simplify:` line gains `bottomShaped= noCallerAnnotation=` (step 3/2) alongside Q1's
existing `undCallerPoly= undLocal= undBodyOnly= undLeak=`. Expected EARLY self-compile:

| after | inlined | undetermined | undCallerPoly | undBodyOnly | bottomShaped |
|---|---:|---:|---:|---:|---:|
| step 0 (baseline) | 1,865 | 864 | 520 | 156 | — |
| step 3 (guard, flag OFF) | ≈1,865 | ≈800 | ≈456 | 156 | ≈1 candidate (64 sites leave `undetermined`) |
| step 5 (flag ON) | **≈2,315** | ≈344 | **≤ 10** | 156 | ≈1 |
| step 6 (R2) | **≈2,465** | ≈196 | ≤ 10 | **≤ 10** | ≈1 |

Reading deviations: `undCallerPoly` staying high with the flag on ⇒ the binder set is not reaching
`determines` (annotation lookup keyed wrongly, or `Nothing` for most globals — check
`noCallerAnnotation`); inlines rising but E2E failing ⇒ a re-minted caller id (R1) or a
bottom-shaped callee slipping the guard (look for `Kernel signature mismatch`); inlines rising far
above ≈2,315 ⇒ `boundOnlyByCaller` accepting non-binder variables (an `unsolved local` being
treated as a binder — the binder set must come from the annotation TYPE only, never from the body).

Then Run-AT-style: two cold runs (LATE defaults, EARLY with the flag), `benchmarks/lss-opt.md`
protocol, dispatch via a separate uprobe run. Expect FLAT on wall (this is +450 inlines out of a
27k-source-site ceiling); the number that matters is the EARLY census and its E2E.

## 7. Risks

- **The §16 alias fix and Q1's census must be in the tree before step 1.** During this plan's
  drafting the file was transiently overwritten from an older copy (2026-09-10 09:26); step 0's
  census-to-the-digit check is the guard against building on the wrong baseline.
- The general kernel-result hazard behind `bottomShaped` (§2.4) has a syntactic proxy, not a
  semantic check. If item 4 (alias forwarding) lands first and forwards a non-bottom kernel wrapper
  whose result type is a callee variable (`Bytes.Decode.decode`-like — Q1 lists it under
  `polyKernel`), `polyKernel` catches it because the body is then a `VarKernel`. Re-run the
  `polyKernel` reasoning after item 4.
- `PreMonoInlineTest`'s expected values must be hand-verified against the flag-OFF arm first;
  the §12 session mis-computed four CHECK lines on the first attempt.

## 8. If built before item 0 (`Name`-typed tree)

`callerBinders` = keys of the annotation's `FreeVars` (names). The substituted type's names are the
caller's; `AssignMVarIds` later assigns them in the caller's `SchemeEnv` — the same id as every
other occurrence — EXCEPT inside a nested `Def`/`TailDef`'s declared type and RHS, which
`rewriteDef` rewrites under `withFreshBinding` (`AssignMVarIds.elm:222-231`, `env = Dict.empty`,
roots kept). That is today's un-annotated-let treatment and `translateLet` defers to the RHS type,
so it is not a soundness hole, but it is a reason the id-typed version (item 0 first) is cleaner:
there, nothing is re-assigned and the question does not arise.

## 9. What not to do

- Do not accept "every free variable is SOME binder somewhere" — only the enclosing definition's
  own annotation binders. An unsolved local treated as a binder is the §12 layout bug again.
- Do not make `bottomShaped` per-call: a bottom callee at a ground result is wrong too (R7).
- Do not touch `hofParam`/`superVar`/`polyKernel`/`rowPoly`; they precede `determines` and are
  candidate-level by design.
- Do not read the win off the inline COUNT alone: the ceiling is 27,130 source sites (report
  §1.4); +450 is a completeness step, not a dispatch result — measure dispatch separately.

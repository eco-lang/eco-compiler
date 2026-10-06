module Compiler.Pipeline.Steps exposing
    ( assignFlagsFor, prepare, prepareEntry
    , PreMono, preMono, checkMinted
    , monomorphize, monomorphizeEntry, checkStageArity, checkLayout
    , inline, prune, checkPruned
    , GlobalOptResult, globalOptCore, cse, dedupe, hoist, globalOpt, checkClosureStaging
    , toGlobalOpt
    )

{-| The compiler's middle end as plain functions: every step a build takes
between the typed global graph and the graph MLIR is generated from, in the
order `Builder.Generate` runs them
(plans/staging-honesty-and-production-test-pipeline.md P1).

`Builder.Generate` calls these inside its `Task` steps, adding reports, phase
timers and the heap-release step boundaries. The test harness
(`TestLogic.TestPipeline`) calls the same functions, so a test compiles a
program exactly the way `eco make` does under the same `EcoConfig`. Nothing in
this module reads the environment or writes output: configuration arrives as
an `EcoConfig`, and every report is built by the caller from the metrics
returned here.

The steps, in order:

1.  `prepare` gives the typed graph its ids (`EntryPrep.assign`).
2.  `preMono` runs the pre-monomorphization passes each behind its flag: alias
    forwarding, η-expansion to declared arity, the pre-mono inliner.
3.  `monomorphize` runs the configured engine.
4.  `inline` runs the post-monomorphization inliner, then `prune` removes the
    specializations it orphaned.
5.  `globalOpt` runs global optimization, then CSE, CAF dedupe and CAF hoisting,
    each behind its flag (`globalOptCore`, `cse`, `dedupe`, `hoist`).

The `check*` functions are the validators a build runs between steps; they
return `Err` with the message a build reports.


# Preparation

@docs assignFlagsFor, prepare, prepareEntry


# Pre-monomorphization

@docs PreMono, preMono, checkMinted


# Monomorphization

@docs monomorphize, monomorphizeEntry, checkStageArity, checkLayout


# Post-monomorphization inlining

@docs inline, prune, checkPruned


# Global optimization

@docs GlobalOptResult, globalOptCore, cse, dedupe, hoist, globalOpt, checkClosureStaging


# Whole pipeline

@docs toGlobalOpt

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.CafCensus as CafCensus
import Compiler.GlobalOpt.CafDedupe as CafDedupe
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.GlobalOpt.CseCensus as CseCensus
import Compiler.GlobalOpt.InlineSimplify as InlineSimplify
import Compiler.GlobalOpt.MonoCse as MonoCse
import Compiler.GlobalOpt.MonoGlobalOptimize as MonoGlobalOptimize
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.GlobalOpt.PreMono.AliasForward as AliasForward
import Compiler.GlobalOpt.PreMono.EtaExpand as EtaExpand
import Compiler.GlobalOpt.PreMono.Fresh as Fresh
import Compiler.GlobalOpt.Staging as Staging
import Compiler.MonoSolver.Diff as MonoDiff
import Compiler.MonoSolver.Monomorphize as MonoSolver
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.ValidateLayout as ValidateLayout
import Compiler.Monomorphize.ValidateLimits as ValidateLimits



-- ============================================================================
-- PREPARATION
-- ============================================================================


{-| The assignment flags for the selected engine. The solver passes its
`LssConfig`'s; the subst and diff engines pass `( False, False )` — changing
those would move their output.
-}
assignFlagsFor : Config.EcoConfig -> ( Bool, Bool )
assignFlagsFor ecoConfig =
    case ecoConfig.mono.engine of
        Config.EngineSolver ->
            ( True, ecoConfig.mono.lss.arrowCensus )

        Config.EngineSubst ->
            ( False, False )

        Config.EngineDiff ->
            ( False, False )


{-| PHASE 0 — `AssignMVarIds`, in front of the pre-mono passes, so they operate
on `MVarId`s rather than on names
(`plans/pre-mono-lss-transforms-00-assign-mvar-ids-first.md`). It also
synthesizes the entry's flags decoder. Identity therefore EXISTS during the
pre-mono passes: anything they create or copy must mint through
`PreMono.Fresh`, and `checkMinted` checks that under `mono.validate`.
-}
prepare : Config.EcoConfig -> TOpt.GlobalGraph Name -> EntryPrep.Assigned
prepare ecoConfig typedGraph =
    prepareEntry ecoConfig "main" typedGraph


{-| `prepare` from the top-level value `entry` instead of `main`. A build
always starts from `main`; a test harness that compiles library modules names
its own entry.
-}
prepareEntry : Config.EcoConfig -> Name -> TOpt.GlobalGraph Name -> EntryPrep.Assigned
prepareEntry ecoConfig entry typedGraph =
    EntryPrep.assign (assignFlagsFor ecoConfig) entry typedGraph



-- ============================================================================
-- PRE-MONOMORPHIZATION
-- ============================================================================


{-| What `preMono` returns: the rewritten graph and each pass's metrics.
A pass that did not run reports its `emptyMetrics`.
-}
type alias PreMono =
    { assigned : EntryPrep.Assigned
    , aliasForward : AliasForward.Metrics
    , etaExpand : EtaExpand.Metrics
    , inline : InlineSimplify.Metrics
    }


{-| The pre-monomorphization passes, in build order.

  - **Alias forwarding** (`plans/pre-mono-lss-transforms-04-alias-forwarding.md`
    §3.6): FIRST after assignment, before η-expansion — η reads the callee's
    declared arity, and after forwarding that is the target's. With the flag
    off and `inline.report` on it runs as a CENSUS and returns the graph
    untouched; with both off it is not called. It mints nothing.
  - **η-expansion** to declared arity
    (`plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md`): with
    the flag off and `inline.report` on it runs as a CENSUS and returns the
    graph and the id allocator UNTOUCHED; with both off it is not called.
    Placed BEFORE the pre-mono inliner (that plan's §2.8) so the inliner sees
    SATURATED calls, and before monomorphization because LSS runs inside the
    solver.
  - **The pre-mono inliner** (`plans/pre-mono-inline-simplify.md`), behind
    `inline.preMono`.

-}
preMono : Config.EcoConfig -> EntryPrep.Assigned -> PreMono
preMono ecoConfig assignedRaw =
    let
        ( assigned0, afwdMetrics ) =
            if ecoConfig.inline.aliasForward || ecoConfig.inline.report then
                let
                    ( gAfwd, stateAfwd, metrics ) =
                        AliasForward.run ecoConfig.inline assignedRaw.mvarState assignedRaw.graph
                in
                ( { assignedRaw | graph = gAfwd, mvarState = stateAfwd }, metrics )

            else
                ( assignedRaw, AliasForward.emptyMetrics )

        ( assignedEta, etaMetrics ) =
            if ecoConfig.inline.etaExpand || ecoConfig.inline.report then
                let
                    ( gEta, stateEta, metrics ) =
                        EtaExpand.run ecoConfig.inline assigned0.mvarState assigned0.graph
                in
                ( { assigned0 | graph = gEta, mvarState = stateEta }, metrics )

            else
                ( assigned0, EtaExpand.emptyMetrics )

        ( assigned1, preInlineMetrics ) =
            if ecoConfig.inline.preMono then
                let
                    ( g1, state1, metrics ) =
                        InlineSimplify.optimize ecoConfig.inline assignedEta.mvarState assignedEta.graph
                in
                ( { assignedEta | graph = g1, mvarState = state1 }, metrics )

            else
                ( assignedEta, InlineSimplify.emptyMetrics )
    in
    { assigned = assigned1
    , aliasForward = afwdMetrics
    , etaExpand = etaMetrics
    , inline = preInlineMetrics
    }


{-| Under `mono.validate` (`ECO_MONO_VALIDATE=1`), check that every pre-mono
pass minted identity for what it created and copied.

The DUPLICATE-id half is the one that earns its keep: a missing id declines
visibly, a repeated one is two bodies under a single member and is silent.

-}
checkMinted : Config.EcoConfig -> EntryPrep.Assigned -> Result String ()
checkMinted ecoConfig assigned =
    if ecoConfig.mono.validate then
        Fresh.assertMinted assigned.graph
            |> Result.mapError (\message -> "pre-mono identity validator: " ++ message)

    else
        Ok ()



-- ============================================================================
-- MONOMORPHIZATION
-- ============================================================================


{-| Choose the monomorphizer engine per `mono.engine`. `EngineSubst` is the
original engine; `EngineSolver` the solver-based one (the default);
`EngineDiff` runs both and asserts their output matches. The `Maybe String` is
the LSS census, present when the solver ran with `lss.report`.
-}
monomorphize : Config.EcoConfig -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String ( Mono.MonoGraph, Maybe String )
monomorphize ecoConfig globalTypeEnv assigned =
    monomorphizeEntry ecoConfig "main" globalTypeEnv assigned


{-| `monomorphize` from the top-level value `entry`; see `prepareEntry`.
-}
monomorphizeEntry : Config.EcoConfig -> Name -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String ( Mono.MonoGraph, Maybe String )
monomorphizeEntry ecoConfig entry globalTypeEnv assigned =
    case ecoConfig.mono.engine of
        Config.EngineSubst ->
            Result.map (\g -> ( g, Nothing )) (Monomorphize.monomorphizeWithLimitsAssigned ecoConfig.mono.limits entry globalTypeEnv assigned)

        Config.EngineSolver ->
            MonoSolver.monomorphizeWithReportAssigned ecoConfig.mono.lss ecoConfig.mono.limits entry globalTypeEnv assigned

        Config.EngineDiff ->
            -- Diff forces lss off internally; no census.
            Result.map (\g -> ( g, Nothing )) (MonoDiff.runAssigned ecoConfig.mono.diffDump entry globalTypeEnv assigned)


{-| HEAP\_078 backstop (`Compiler.Monomorphize.ValidateLimits`): `Err` with a
located `STAGE ARITY LIMIT` message when some closure has more parameters plus
captured variables than a closure stage can hold. A build runs it after
monomorphization and again after inlining and global optimization.
-}
checkStageArity : Mono.MonoGraph -> Result String Mono.MonoGraph
checkStageArity g =
    case ValidateLimits.check g of
        [] ->
            Ok g

        violations ->
            Err ("STAGE ARITY LIMIT\n" ++ String.join "\n" violations)


{-| MONO\_029 layout-agreement validator, under `mono.validate`
(`ECO_MONO_VALIDATE=1`): engine-agnostic, fails on any layout-disagreeing
views.
-}
checkLayout : Config.EcoConfig -> Mono.MonoGraph -> Result String Mono.MonoGraph
checkLayout ecoConfig g =
    if ecoConfig.mono.validate then
        case ValidateLayout.validate g of
            [] ->
                Ok g

            violations ->
                Err
                    ("ECO_MONO_VALIDATE: "
                        ++ String.fromInt (List.length violations)
                        ++ " MONO_029 layout violations\n"
                        ++ String.join "\n" violations
                    )

    else
        Ok g



-- ============================================================================
-- POST-MONOMORPHIZATION INLINING
-- ============================================================================


{-| The post-monomorphization inliner under the build's effective inline
configuration.

`list.chunks` keeps the shunted combinators' call sites intact: their tiny
delegate bodies (reverse = foldl cons [] etc.) are otherwise threshold-inlined
everywhere, and the generation-time kernel shunt
(`Generate.MLIR.Functions.listChunksShunt`) only rewrites the spec definitions,
not pasted copies.

`list.mapTemplate` does the same one rung up: the template replaces the
`List.map` spec DEFINITION at generation time, so a foldr body already pasted
into a caller would keep the old lowering and silently escape the template.
Blacklisting is name-level and wholesale by necessity: this pass runs BEFORE
GlobalOpt/AbiCloning, so the licensed SET does not exist yet. With the flag on,
UNLICENSED map sites are behaviourally identical but not necessarily
byte-identical — their specs stop being inline candidates.

`inline.postMono` (`ECO_INLINE_POST_MONO=0`) is the EARLY arm of the position
A/B (plans/pre-mono-inline-simplify.md §7): off, the pass is skipped.

-}
inline : Config.EcoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, MonoInlineSimplify.Metrics )
inline ecoConfig monoGraph0 =
    let
        chunkBlacklist =
            if ecoConfig.list.chunks then
                [ "List.reverse", "List.append", "List.concat", "List.take", "List.drop" ]

            else
                []

        mapTemplateBlacklist =
            if ecoConfig.list.mapTemplate then
                [ "List.map" ]

            else
                []

        effectiveInlineConfig =
            case chunkBlacklist ++ mapTemplateBlacklist of
                [] ->
                    ecoConfig.inline

                extra ->
                    let
                        cfg =
                            ecoConfig.inline
                    in
                    { cfg | blacklist = cfg.blacklist ++ extra }
    in
    if ecoConfig.inline.postMono then
        MonoInlineSimplify.optimize effectiveInlineConfig monoGraph0

    else
        ( monoGraph0, MonoInlineSimplify.emptyMetrics )


{-| POST-INLINE DEAD-SPEC PRUNE (plans/post-inline-dead-spec-prune.md), behind
`inline.pruneDead`. The inliner orphans a specialization whenever it inlines
the only reference to it. HERE is the only position where a
`MonoVarGlobal`-reachability is exact — everything that references a spec by
another route (AbiCloning's `fastEvaluatorSpec`, post-settle devirt targets,
CafHoist's mints) runs after global optimization.
-}
prune : Config.EcoConfig -> Mono.MonoGraph -> Mono.MonoGraph
prune ecoConfig inlinedGraph =
    if ecoConfig.inline.pruneDead then
        Prune.pruneAfterInline inlinedGraph

    else
        inlinedGraph


{-| Under `mono.validate` (`ECO_MONO_VALIDATE=1`) with the prune on, check that
the prune left the graph CLOSED: every `MonoVarGlobal` in a live node names a
live node (`plans/post-inline-dead-spec-prune.md` §4 R1, MONO\_011).
Reachability is only as good as the adjacency it walks, and an adjacency that
misses a reference shape prunes a live spec silently.
-}
checkPruned : Config.EcoConfig -> Mono.MonoGraph -> Result String ()
checkPruned ecoConfig (Mono.MonoGraph record) =
    if not (ecoConfig.mono.validate && ecoConfig.inline.pruneDead) then
        Ok ()

    else
        let
            isLive specId =
                case Array.get specId record.nodes of
                    Just (Just _) ->
                        True

                    _ ->
                        False

            -- Hoisted: `collectSpecEdges` walks the whole graph, so computing
            -- it inside the fold would be quadratic in the spec count.
            edges =
                MonoTraverse.collectSpecEdges record.nodes

            dangling =
                Array.foldl
                    (\entry ( specId, acc ) ->
                        case entry of
                            Nothing ->
                                ( specId + 1, acc )

                            Just _ ->
                                ( specId + 1
                                , case Array.get specId edges |> Maybe.andThen identity of
                                    Just targets ->
                                        List.foldl
                                            (\t a ->
                                                if isLive t then
                                                    a

                                                else
                                                    ( specId, t ) :: a
                                            )
                                            acc
                                            targets

                                    Nothing ->
                                        acc
                                )
                    )
                    ( 0, [] )
                    record.nodes
                    |> Tuple.second
        in
        case dangling of
            [] ->
                Ok ()

            ( from, to ) :: rest ->
                Err
                    ("MONO_011: post-inline prune removed a LIVE specialization — spec "
                        ++ String.fromInt from
                        ++ " references pruned spec "
                        ++ String.fromInt to
                        ++ " ("
                        ++ String.fromInt (1 + List.length rest)
                        ++ " dangling references in total). The edge collector "
                        ++ "(MonoTraverse.collectSpecEdges) missed a reference shape."
                    )



-- ============================================================================
-- GLOBAL OPTIMIZATION
-- ============================================================================


{-| What global optimization returns besides the final graph: each step's
stats and the census lines rendered from graphs that are dead by the time a
report is written.
-}
type alias GlobalOptResult =
    { goStats : MonoGlobalOptimize.GlobalOptStats
    , cseStats : MonoCse.Stats
    , cseCensus : Maybe String
    , dedupeStats : CafDedupe.Stats
    , cafCensusPre : Maybe String
    , hoistStats : CafHoist.Stats
    }


{-| `MonoGlobalOptimize.globalOptimizeWithStats` under the build's
configuration.
-}
globalOptCore : Config.EcoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, MonoGlobalOptimize.GlobalOptStats )
globalOptCore ecoConfig simplifiedGraph =
    MonoGlobalOptimize.globalOptimizeWithStats
        ecoConfig.mono.lss.stamp.census
        ecoConfig.mono.stagingReport
        ecoConfig.borrow
        ecoConfig.list.mapTemplate
        simplifiedGraph


{-| kernel-opt-13 C2: bounded-scope CSE of pure calls (`cse.enabled`), with
its C1 census under `cse.report` taken on the same input graph. Runs
post-annotation, because it adds MonoLet bindings and annotateCallStaging is
O(2^let-depth); and BEFORE CafDedupe, so CSE never has to reason about specs
dedupe is about to merge away.
-}
cse : Config.EcoConfig -> ( Mono.MonoGraph, MonoGlobalOptimize.GlobalOptStats ) -> ( Mono.MonoGraph, GlobalOptResult )
cse ecoConfig ( goGraph, goStats ) =
    let
        cseCfg =
            ecoConfig.cse

        cseCensus =
            if cseCfg.report then
                Just (CseCensus.report "" cseCfg.minCost goGraph)

            else
                Nothing

        ( cseGraph, cseStats ) =
            if cseCfg.enabled then
                MonoCse.run
                    { minCost = cseCfg.minCost, maxPerDef = cseCfg.maxPerDef }
                    goGraph

            else
                ( goGraph, MonoCse.emptyStats )
    in
    ( cseGraph
    , { goStats = goStats
      , cseStats = cseStats
      , cseCensus = cseCensus
      , dedupeStats = CafDedupe.emptyStats
      , cafCensusPre = Nothing
      , hoistStats = CafHoist.emptyStats
      }
    )


{-| CAF spec dedupe (`cafMemo.dedupe`): merge structurally identical nullary
specs BEFORE census/hoist so downstream counts see the deduped graph; then the
inner-CAF opportunity census (`cafMemo.census`) over the PRE-hoist graph.
-}
dedupe : Config.EcoConfig -> ( Mono.MonoGraph, GlobalOptResult ) -> ( Mono.MonoGraph, GlobalOptResult )
dedupe ecoConfig ( cseGraph, carry ) =
    let
        cafMemo =
            ecoConfig.cafMemo

        ( optimizedGraph, dedupeStats ) =
            if cafMemo.dedupe then
                CafDedupe.run cseGraph

            else
                ( cseGraph, CafDedupe.emptyStats )

        cafCensusPre =
            if cafMemo.census then
                Just (CafCensus.report "caf-census" { minNodes = cafMemo.hoist.minNodes } optimizedGraph)

            else
                Nothing
    in
    ( optimizedGraph, { carry | dedupeStats = dedupeStats, cafCensusPre = cafCensusPre } )


{-| CAF hoisting (`cafMemo.hoist.enabled`; plans/caf-hoist-closed-expressions.md).
-}
hoist : Config.EcoConfig -> ( Mono.MonoGraph, GlobalOptResult ) -> ( Mono.MonoGraph, GlobalOptResult )
hoist ecoConfig ( optimizedGraph, carry ) =
    let
        hoistCfg =
            ecoConfig.cafMemo.hoist

        ( hoistedGraph, hoistStats ) =
            if hoistCfg.enabled then
                CafHoist.run
                    { minNodes = hoistCfg.minNodes
                    , maxHoists = hoistCfg.maxHoists
                    }
                    optimizedGraph

            else
                ( optimizedGraph, CafHoist.emptyStats )
    in
    ( hoistedGraph, { carry | hoistStats = hoistStats } )


{-| The whole global optimization step: `globalOptCore`, then `cse`, `dedupe`
and `hoist`. A build runs the four as separate `Task` steps; the result is
the same.
-}
globalOpt : Config.EcoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, GlobalOptResult )
globalOpt ecoConfig g =
    globalOptCore ecoConfig g
        |> cse ecoConfig
        |> dedupe ecoConfig
        |> hoist ecoConfig



{-| GOPT\_001 under `mono.validate` (`ECO_MONO_VALIDATE=1`): every closure has
as many parameters as its type's first stage
(`Compiler.GlobalOpt.Staging.checkClosureStaging`). A build runs it after
global optimization.
-}
checkClosureStaging : Config.EcoConfig -> Mono.MonoGraph -> Result String Mono.MonoGraph
checkClosureStaging ecoConfig g =
    if ecoConfig.mono.validate then
        case Staging.checkClosureStaging g of
            [] ->
                Ok g

            violations ->
                Err ("ECO_MONO_VALIDATE: " ++ String.fromInt (List.length violations) ++ " GOPT_001 violations\n" ++ String.join "\n" violations)

    else
        Ok g



-- ============================================================================
-- WHOLE PIPELINE
-- ============================================================================


{-| Every step from the typed global graph to the graph MLIR is generated
from, with every validator a build runs, as one function: `prepare`, `preMono`,
`checkMinted`, `monomorphize`, `checkStageArity`, `checkLayout`, `inline`,
`prune`, `checkPruned`, `globalOpt`, `checkStageArity`, `checkClosureStaging`.
Returns the
monomorphized graph (before inlining) and the final graph.
-}
toGlobalOpt : Config.EcoConfig -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String { monoGraph : Mono.MonoGraph, optimized : Mono.MonoGraph }
toGlobalOpt ecoConfig globalTypeEnv typedGraph =
    let
        pre =
            preMono ecoConfig (prepare ecoConfig typedGraph)
    in
    checkMinted ecoConfig pre.assigned
        |> Result.andThen (\_ -> monomorphize ecoConfig globalTypeEnv pre.assigned)
        |> Result.andThen (\( g, _ ) -> checkStageArity g)
        |> Result.andThen (checkLayout ecoConfig)
        |> Result.andThen
            (\monoGraph ->
                let
                    simplified =
                        prune ecoConfig (Tuple.first (inline ecoConfig monoGraph))
                in
                checkPruned ecoConfig simplified
                    |> Result.andThen (\_ -> checkStageArity (Tuple.first (globalOpt ecoConfig simplified)))
                    |> Result.andThen (checkClosureStaging ecoConfig)
                    |> Result.map (\optimized -> { monoGraph = monoGraph, optimized = optimized })
            )

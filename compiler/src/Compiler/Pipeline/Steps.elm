module Compiler.Pipeline.Steps exposing
    ( assignFlagsFor, prepare, prepareEntry
    , PreMono, preMono, checkMinted
    , monomorphize, monomorphizeEntry, checkStageArity, checkLayout
    , inline, prune, checkPruned
    , GlobalOptResult, globalOptCore, cse, dedupe, hoist, globalOpt, checkClosureStaging
    )

{-| The compiler's middle end as plain functions, so that anything that
compiles a program can run the same steps under the same configuration.

The middle end is every step between the typed global graph that local
optimization produces and the monomorphized graph that MLIR is generated from.
Each step here is a pure function of an `EcoConfig` and a graph. Nothing in
this module reads the environment or writes output: configuration arrives as
an `EcoConfig`, and the metrics, statistics and census text each step returns
are left for the caller to report.

The steps, in order:

1.  `prepare` gives the typed graph its ids and the entry's flags decoder.
2.  `preMono` runs the pre-monomorphization passes, each behind its flag:
    alias forwarding, η-expansion to declared arity, and the pre-mono inliner.
3.  `monomorphize` runs the configured engine.
4.  `inline` runs the post-monomorphization inliner, then `prune` removes the
    specializations it left unreferenced.
5.  `globalOpt` runs global optimization, then CSE, CAF dedupe and CAF
    hoisting, each behind its flag. `globalOptCore`, `cse`, `dedupe` and
    `hoist` are the same four pieces taken one at a time.

The `check*` functions are validators to run between steps. Each returns `Err`
with a message to report when it finds a violation; most of them check only
under `mono.validate`.


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


{-| Returns the `( useSolverRoots, censusOn )` flags that id assignment
(`Compiler.Monomorphize.EntryPrep.assign`) takes for the configured engine.

The solver engine gets `True` and `mono.lss.arrowCensus`. The subst and diff
engines get `( False, False )`.

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


{-| Returns the typed graph with its ids assigned and, when `main` is a
`Program`, its flags decoder added, as `Compiler.Monomorphize.EntryPrep.assign`
describes.

Ids exist from here on, so a pre-mono pass that creates or copies a node must
mint fresh ids for it through `Compiler.GlobalOpt.PreMono.Fresh`.

-}
prepare : Config.EcoConfig -> TOpt.GlobalGraph Name -> EntryPrep.Assigned
prepare ecoConfig typedGraph =
    prepareEntry ecoConfig "main" typedGraph


{-| Returns what `prepare` does, but taking the top-level value named `entry`
as the entry point instead of `main`.
-}
prepareEntry : Config.EcoConfig -> Name -> TOpt.GlobalGraph Name -> EntryPrep.Assigned
prepareEntry ecoConfig entry typedGraph =
    EntryPrep.assign (assignFlagsFor ecoConfig) entry typedGraph



-- ============================================================================
-- PRE-MONOMORPHIZATION
-- ============================================================================


{-| What `preMono` returns: the rewritten graph with its id state, and each
pass's metrics. A pass that was not run reports its `emptyMetrics`.
-}
type alias PreMono =
    { assigned : EntryPrep.Assigned
    , aliasForward : AliasForward.Metrics
    , etaExpand : EtaExpand.Metrics
    , inline : InlineSimplify.Metrics
    }


{-| Returns the prepared graph after the pre-monomorphization passes, with
each pass's metrics.

The passes run in this order, each on the output of the one before:

  - Alias forwarding (`Compiler.GlobalOpt.PreMono.AliasForward`), which points
    references to a definition that only names another global at that global.
    It runs first because η-expansion reads a callee's declared arity, and
    after forwarding that is the target's arity.
  - η-expansion to declared arity (`Compiler.GlobalOpt.PreMono.EtaExpand`).
    It runs before the inliner, so that the inliner sees saturated calls.
  - The pre-mono inliner (`Compiler.GlobalOpt.InlineSimplify`), run only when
    `inline.preMono` is on.

Alias forwarding runs when `inline.aliasForward` or `inline.report` is on, and
η-expansion when `inline.etaExpand` or `inline.report` is on. With only
`inline.report` on, the pass is run for its metrics and leaves the graph and
id state unchanged.

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


{-| Under `mono.validate`, checks the bodies of the `Define`, `TrackedDefine`
and port nodes for missing or repeated lambda and arrow ids, with
`Compiler.GlobalOpt.PreMono.Fresh.assertMinted`. Returns `Ok ()` when
`mono.validate` is off.

A repeated id is the failure this exists for: a copy that kept its ids leaves
two bodies under one id. `Cycle` nodes are not checked, and arrows that share
a solver root, and so one arrow id, also fail.

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


{-| Returns the monomorphized graph for the program whose entry is `main`,
using the engine `mono.engine` selects, together with the LSS census text.

`EngineSubst` and `EngineSolver` each run one engine. `EngineDiff` runs both
and fails if their outputs differ; it does not use `mono.limits` or
`mono.lss` (see `Compiler.MonoSolver.Diff`). The census is present only when
the solver engine ran and produced one, which `mono.lss.report` controls.

-}
monomorphize : Config.EcoConfig -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String ( Mono.MonoGraph, Maybe String )
monomorphize ecoConfig globalTypeEnv assigned =
    monomorphizeEntry ecoConfig "main" globalTypeEnv assigned


{-| Returns what `monomorphize` does, but taking the top-level value named
`entry` as the entry point instead of `main`.
-}
monomorphizeEntry : Config.EcoConfig -> Name -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String ( Mono.MonoGraph, Maybe String )
monomorphizeEntry ecoConfig entry globalTypeEnv assigned =
    case ecoConfig.mono.engine of
        Config.EngineSubst ->
            Result.map (\g -> ( g, Nothing )) (Monomorphize.monomorphizeWithLimitsAssigned ecoConfig.mono.limits entry globalTypeEnv assigned)

        Config.EngineSolver ->
            MonoSolver.monomorphizeWithReportAssigned ecoConfig.mono.lss ecoConfig.mono.limits entry globalTypeEnv assigned

        Config.EngineDiff ->
            Result.map (\g -> ( g, Nothing )) (MonoDiff.runAssigned ecoConfig.mono.diffDump entry globalTypeEnv assigned)


{-| Returns the graph unchanged, or `Err` with a `STAGE ARITY LIMIT` message
listing every closure whose parameters plus captured variables are more than a
closure stage can hold (`Compiler.Monomorphize.ValidateLimits.check`).

Unlike the other validators, this check is not behind `mono.validate`.

-}
checkStageArity : Mono.MonoGraph -> Result String Mono.MonoGraph
checkStageArity g =
    case ValidateLimits.check g of
        [] ->
            Ok g

        violations ->
            Err ("STAGE ARITY LIMIT\n" ++ String.join "\n" violations)


{-| Under `mono.validate`, returns the graph unchanged or `Err` with every
layout disagreement `Compiler.Monomorphize.ValidateLayout.validate` finds.
Returns the graph unchanged when `mono.validate` is off.
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


{-| Returns the graph after the post-monomorphization inliner
(`Compiler.GlobalOpt.MonoInlineSimplify`), with its metrics, or the graph
unchanged and empty metrics when `inline.postMono` is off.

Two list options add names to the inliner's blacklist, because generation
later replaces those functions' specialization definitions, and a copy of a
body already pasted into a caller would escape the replacement. With
`list.chunks` on, `List.reverse`, `List.append`, `List.concat`, `List.take` and
`List.drop` are not inlined. With `list.mapTemplate` on, `List.map` is not
inlined. The blacklist is by name and covers every specialization of each
function.

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


{-| Returns the graph with the specializations that nothing reachable still
references removed (`Compiler.Monomorphize.Prune.pruneAfterInline`), when
`inline.pruneDead` is on; otherwise the graph unchanged.

Inlining leaves a specialization unreferenced when it inlines the only call to
it. Reachability is computed from the references in the current bodies.

-}
prune : Config.EcoConfig -> Mono.MonoGraph -> Mono.MonoGraph
prune ecoConfig inlinedGraph =
    if ecoConfig.inline.pruneDead then
        Prune.pruneAfterInline inlinedGraph

    else
        inlinedGraph


{-| Under `mono.validate` with `inline.pruneDead` on, checks that the graph is
closed: that every specialization a live node references is itself live.
Returns `Ok ()` when either flag is off.

The references are collected by `Compiler.Monomorphize.MonoTraverse.collectSpecEdges`,
the same collector the prune walks, so it catches a prune that removed a
specialization still referenced through a shape the collector sees; a
reference shape the collector misses goes undetected here too. The `Err`
message names the first dangling reference found and the total count.

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


{-| What the global optimization step returns besides the final graph: each
piece's statistics, and the census texts, which are taken from intermediate
graphs. A piece that was not run reports empty statistics, and a census that
was not asked for is `Nothing`.
-}
type alias GlobalOptResult =
    { goStats : MonoGlobalOptimize.GlobalOptStats
    , cseStats : MonoCse.Stats
    , cseCensus : Maybe String
    , dedupeStats : CafDedupe.Stats
    , cafCensusPre : Maybe String
    , hoistStats : CafHoist.Stats
    }


{-| Returns the graph after `Compiler.GlobalOpt.MonoGlobalOptimize` global
optimization, with its statistics, under the configuration's
`mono.lss.stamp.census`, `mono.stagingReport`, `borrow` and `list.mapTemplate`
settings.
-}
globalOptCore : Config.EcoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, MonoGlobalOptimize.GlobalOptStats )
globalOptCore ecoConfig simplifiedGraph =
    MonoGlobalOptimize.globalOptimizeWithStats
        ecoConfig.mono.lss.stamp.census
        ecoConfig.mono.stagingReport
        ecoConfig.borrow
        ecoConfig.list.mapTemplate
        simplifiedGraph


{-| Returns the graph after common subexpression elimination of pure calls
(`Compiler.GlobalOpt.MonoCse`) when `cse.enabled` is on, and starts the
`GlobalOptResult` with the global optimization statistics it is given.

Under `cse.report`, the CSE census is taken of the input graph, before
elimination. This piece comes after `globalOptCore` and before `dedupe`.

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


{-| Returns the graph with structurally identical nullary specializations
merged (`Compiler.GlobalOpt.CafDedupe`) when `cafMemo.dedupe` is on, recording
the statistics in the result.

Under `cafMemo.census`, the CAF census is then taken of the deduplicated
graph, so before `hoist` runs.

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


{-| Returns the graph after CAF hoisting (`Compiler.GlobalOpt.CafHoist`) when
`cafMemo.hoist.enabled` is on, recording the statistics in the result.
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


{-| Returns the graph after the whole global optimization step:
`globalOptCore`, then `cse`, `dedupe` and `hoist`.
-}
globalOpt : Config.EcoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, GlobalOptResult )
globalOpt ecoConfig g =
    globalOptCore ecoConfig g
        |> cse ecoConfig
        |> dedupe ecoConfig
        |> hoist ecoConfig



{-| Under `mono.validate`, returns the graph unchanged or `Err` with every
violation that
`Compiler.GlobalOpt.Staging.checkClosureStaging` finds: a closure or tail
function whose parameter count differs from its type's first stage. Returns
the graph unchanged when `mono.validate` is off.
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


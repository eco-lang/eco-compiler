module Compiler.Pipeline.Steps exposing
    ( assignFlagsFor, prepareRoot
    , PreMono, preMono, checkMinted
    , monomorphize, monomorphizeEntry, checkStageArity, checkLayout
    , representation
    , inline, knownCtorCase, prune, checkPruned
    , GlobalOptResult, globalOptCore, cse, dedupe, hoist, checkClosureStaging
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

1.  `prepareRoot` gives the typed graph its ids and the entry's flags decoder.
2.  `preMono` runs the pre-monomorphization passes, each behind its flag:
    alias forwarding, η-expansion to declared arity, and the pre-mono inliner.
3.  `monomorphize` runs the configured engine.
4.  `inline` runs the post-monomorphization inliner, then `prune` removes the
    specializations it left unreferenced.
5.  `globalOptCore` runs global optimization, then `cse`, `dedupe` and
    `hoist` run CSE, CAF dedupe and CAF hoisting, each behind its flag.

The `check*` functions are validators to run between steps. Each returns `Err`
with a message to report when it finds a violation; most of them check only
under `mono.validate`.


# Preparation

@docs assignFlagsFor, prepareRoot


# Pre-monomorphization

@docs PreMono, preMono, checkMinted


# Monomorphization

@docs monomorphize, monomorphizeEntry, checkStageArity, checkLayout


# Representation

@docs representation


# Post-monomorphization inlining

@docs inline, knownCtorCase, prune, checkPruned


# Global optimization

@docs GlobalOptResult, globalOptCore, cse, dedupe, hoist, checkClosureStaging

-}

import Array
import Compiler.Config as Config
import Compiler.Core.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.IR.Typed.TypeEnv as TypeEnv
import Compiler.MonoOpt.CafCensus as CafCensus
import Compiler.MonoOpt.CafDedupe as CafDedupe
import Compiler.MonoOpt.CafHoist as CafHoist
import Compiler.MonoOpt.Cse as MonoCse
import Compiler.MonoOpt.CseCensus as CseCensus
import Compiler.MonoOpt.EraseWrappers as EraseWrappers
import Compiler.MonoOpt.FloatMinMax as FloatMinMax
import Compiler.MonoOpt.GlobalOptimize as MonoGlobalOptimize
import Compiler.MonoOpt.InlineSimplify as MonoInlineSimplify
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.MonoOpt.KnownCtorCase as KnownCtorCase
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Compiler.MonoOpt.Representation as Representation
import Compiler.MonoOpt.Staging as Staging
import Compiler.Monomorphize.Diff as MonoDiff
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.RepresentationMeets as RepresentationMeets
import Compiler.Monomorphize.Solver.Monomorphize as MonoSolver
import Compiler.Monomorphize.Subst.Monomorphize as Monomorphize
import Compiler.Monomorphize.ValidateLayout as ValidateLayout
import Compiler.Monomorphize.ValidateLimits as ValidateLimits
import Compiler.PreMono.AliasForward as AliasForward
import Compiler.PreMono.EntryPrep as EntryPrep
import Compiler.PreMono.EtaExpand as EtaExpand
import Compiler.PreMono.Fresh as Fresh
import Compiler.PreMono.InlineSimplify as InlineSimplify
import Set



-- ============================================================================
-- PREPARATION
-- ============================================================================


{-| Returns the `( useSolverRoots, censusOn )` flags that id assignment
(`Compiler.PreMono.EntryPrep.assignIn`) takes for the configured engine.

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


{-| Returns the typed graph with its ids assigned and, when the `main` of
module `rootHome` is a `Program`, its flags decoder added, as
`Compiler.PreMono.EntryPrep.assignIn` describes.

Ids exist from here on, so a pre-mono pass that creates or copies a node must
mint fresh ids for it through `Compiler.PreMono.Fresh`.

-}
prepareRoot : Config.EcoConfig -> ModuleName.Canonical -> TOpt.GlobalGraph Name -> EntryPrep.Assigned
prepareRoot ecoConfig rootHome typedGraph =
    EntryPrep.assignIn (assignFlagsFor ecoConfig) rootHome "main" typedGraph



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

  - Alias forwarding (`Compiler.PreMono.AliasForward`), which points
    references to a definition that only names another global at that global.
    It runs first because η-expansion reads a callee's declared arity, and
    after forwarding that is the target's arity.
  - η-expansion to declared arity (`Compiler.PreMono.EtaExpand`).
    It runs before the inliner, so that the inliner sees saturated calls.
  - The pre-mono inliner (`Compiler.PreMono.InlineSimplify`), run only when
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
`Compiler.PreMono.Fresh.assertMinted`. Returns `Ok ()` when
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
`mono.lss` (see `Compiler.Monomorphize.Diff`). The census is present only when
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
-- REPRESENTATION
-- ============================================================================


{-| Runs the representation passes of plans/constructor-representation-levels.md
that `repr` switches on, between `checkLayout` and `inline`: `EraseWrappers`
under `repr.eraseWrappers`. Returns the graph with one report line per pass
that ran.

Under `mono.validate` or `repr.validate` it then checks the result, with or
without the passes: MONO_031 (`EraseWrappers.check`) and the representation
meets (`RepresentationMeets.validate`, MONO_029 interior slot kinds and
MONO_033), and returns `Err` with every violation. With every switch off the
graph is returned unchanged and nothing is computed.

-}
representation : Config.EcoConfig -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Result String ( Mono.MonoGraph, List String )
representation ecoConfig typeEnv graph =
    let
        anyPass =
            ecoConfig.repr.eraseWrappers || ecoConfig.repr.nullableMaybe

        checks =
            ecoConfig.mono.validate || ecoConfig.repr.validate

        -- The constructor census marks the kernel-visible classes (KV0), with or without the passes.
        withCensusKv g =
            case ( ecoConfig.repr.census, g ) of
                ( Just _, Mono.MonoGraph r ) ->
                    let
                        repr =
                            r.repr
                    in
                    Mono.MonoGraph { r | repr = { repr | kernelVisible = KernelVisible.ctorList (KernelVisible.compute typeEnv g) } }

                ( Nothing, _ ) ->
                    g
    in
    if not anyPass && not checks then
        Ok ( withCensusKv graph, [] )

    else
        let
            -- Kernel visibility and the meets are taken once, on the graph before the passes; the
            -- nullable pass gets them carried over the erasure (`eraseType`), which is what a second
            -- collection on the erased graph would find, up to the meets of removed constructor calls.
            -- Under `checks` the nullable decision is compared with one taken from a second collection.
            kv =
                if anyPass then
                    KernelVisible.compute typeEnv graph

                else
                    KernelVisible.empty

            meets =
                if anyPass then
                    RepresentationMeets.collect graph

                else
                    []

            -- The decisions first (`EraseWrappers.plan`, `NullableMaybe.choose`), then one rewrite of the
            -- nodes for both (`Representation.run`).
            plan =
                if ecoConfig.repr.eraseWrappers then
                    EraseWrappers.plan
                        (if ecoConfig.repr.eraseUnboxed then
                            { allowUnboxed = True
                            , meetsOk = EraseWrappers.consistentWith meets
                            , meets = meets
                            }

                         else
                            { allowUnboxed = False, meetsOk = identity, meets = meets }
                        )
                        kv
                        graph

                else
                    EraseWrappers.noPlan graph

            erasing =
                not (EraseWrappers.erasableIsEmpty plan.erasable)

            -- Erasure changes the instantiations the set and the meets hold (`Maybe (W Rec)` becomes
            -- `Maybe Rec`), so both are carried over it.
            ( kvErased, meetsErased ) =
                if erasing then
                    ( EraseWrappers.translateKv plan.erasable kv
                    , RepresentationMeets.translate (EraseWrappers.eraseType plan.erasable) meets
                    )

                else
                    ( kv, meets )

            nullOpts =
                { userTypes = ecoConfig.repr.nullableUser }

            choice =
                if ecoConfig.repr.nullableMaybe then
                    Just (NullableMaybe.choose nullOpts kvErased meetsErased plan.ctorShapes)

                else
                    Nothing

            ( nulled, eraseStats, nullStats ) =
                Representation.run plan choice graph

            eraseReport =
                if ecoConfig.repr.eraseWrappers then
                    [ EraseWrappers.renderStats eraseStats
                        ++ "; kernel-visible type constructors "
                        ++ String.fromInt (KernelVisible.size kv)
                        ++ " (from "
                        ++ String.fromInt (KernelVisible.rootCount kv)
                        ++ " root types); meets "
                        ++ String.fromInt (List.length meets)
                    ]

                else
                    []

            nullReport =
                case nullStats of
                    Just st ->
                        [ NullableMaybe.renderStats st ]

                    Nothing ->
                        []

            -- The carried-over set and meets against a second collection on the erased graph: the
            -- recollected instance set must be within the carried-over one, the two meet lists must hold
            -- the same meets (by layout keys and `root`), and the nullable decision must be the same.
            carryViolations =
                case ( checks, erasing ) of
                    ( True, True ) ->
                        let
                            ( erased, _, _ ) =
                                Representation.run plan Nothing graph

                            kvRecollected =
                                KernelVisible.compute typeEnv erased

                            meetsRecollected =
                                RepresentationMeets.collect erased

                            meetKeys ms =
                                List.map
                                    (\m ->
                                        Mono.toComparableLayoutType m.a
                                            ++ " | "
                                            ++ Mono.toComparableLayoutType m.b
                                            ++ (if m.root then
                                                    " | root"

                                                else
                                                    " | interior"
                                               )
                                    )
                                    ms
                                    |> Set.fromList

                            carriedKeys =
                                meetKeys meetsErased

                            recollectedKeys =
                                meetKeys meetsRecollected

                            nullableKeys (Mono.MonoGraph r) =
                                Mono.layoutMapFoldl (\t _ acc -> Mono.toComparableLayoutType t :: acc) [] r.repr.nullable
                                    |> Set.fromList

                            decisionDiffers =
                                ecoConfig.repr.nullableMaybe
                                    && (nullableKeys (Tuple.first (NullableMaybe.run nullOpts kvRecollected meetsRecollected erased))
                                            /= nullableKeys nulled
                                       )

                            sample keys =
                                Set.toList keys |> List.take 5 |> String.join "; "
                        in
                        List.filterMap identity
                            [ if KernelVisible.instancesSubset kvRecollected kvErased then
                                Nothing

                              else
                                Just "representation: the kernel-visibility set carried over the erasure misses an instance a second collection finds"
                            , if carriedKeys == recollectedKeys then
                                Nothing

                              else
                                Just
                                    ("representation: the meets carried over the erasure differ from a second collection; only carried: "
                                        ++ sample (Set.diff carriedKeys recollectedKeys)
                                        ++ "; only recollected: "
                                        ++ sample (Set.diff recollectedKeys carriedKeys)
                                    )
                            , if decisionDiffers then
                                Just "representation: the nullable types chosen from the kernel-visibility set and meets carried over the erasure differ from those chosen from a second collection"

                              else
                                Nothing
                            ]

                    _ ->
                        []

            -- RepresentationMeets reports the meets of the graph as it is. Some exist before any pass
            -- (MONO_021: a spec that keeps a type variable nothing fixed, reached by a concrete view
            -- whose values it never reads), so with a pass on only the violations it introduced count.
            ( violations, baselineReport ) =
                if checks then
                    let
                        after =
                            RepresentationMeets.validate nulled
                    in
                    if anyPass then
                        let
                            before =
                                Set.fromList (RepresentationMeets.validate graph)
                        in
                        ( carryViolations ++ EraseWrappers.check nulled ++ List.filter (\v -> not (Set.member v before)) after, [] )

                    else
                        ( [], [ "repr-validate: " ++ String.fromInt (List.length after) ++ " pre-existing interior meets of differing slot kinds" ++ String.concat (List.map (\v -> "\n  " ++ v) after) ] )

                else
                    ( [], [] )
        in
        case violations of
            [] ->
                Ok ( withCensusKv nulled, eraseReport ++ nullReport ++ baselineReport )

            _ ->
                Err
                    ("ECO_REPR_VALIDATE: "
                        ++ String.fromInt (List.length violations)
                        ++ " representation violations\n"
                        ++ String.join "\n" violations
                    )



-- ============================================================================
-- POST-MONOMORPHIZATION INLINING
-- ============================================================================


{-| Returns the graph after the post-monomorphization inliner
(`Compiler.MonoOpt.InlineSimplify`), with its metrics, or the graph
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
    -- Float max / min / clamp get IEEE 754-2019 bodies first (CGEN_086), so inlined copies carry them.
    let
        monoGraph1 =
            FloatMinMax.rewrite monoGraph0
    in
    if ecoConfig.inline.postMono then
        MonoInlineSimplify.optimize effectiveInlineConfig monoGraph1

    else
        ( monoGraph1, MonoInlineSimplify.emptyMetrics )


{-| Folds each `case` on a value built by a known constructor in the same
function (`Compiler.MonoOpt.KnownCtorCase`, plans/constructor-representation-levels.md
K1) under `repr.knownCtorCase`, and returns the graph with the census line of
such sites (K0), which is counted whether or not the fold is on. Run after
`inline`, whose inlining creates most of the sites.
-}
knownCtorCase : Config.EcoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, String )
knownCtorCase ecoConfig graph =
    if ecoConfig.repr.knownCtorCase || ecoConfig.inline.report then
        KnownCtorCase.run { fold = ecoConfig.repr.knownCtorCase } graph
            |> Tuple.mapSecond KnownCtorCase.renderStats

    else
        ( graph, "" )


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

The references are collected by `Compiler.IR.Mono.Traverse.collectSpecEdges`,
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


{-| Returns the graph after `Compiler.MonoOpt.GlobalOptimize` global
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
(`Compiler.MonoOpt.Cse`) when `cse.enabled` is on, and starts the
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
merged (`Compiler.MonoOpt.CafDedupe`) when `cafMemo.dedupe` is on, recording
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


{-| Returns the graph after CAF hoisting (`Compiler.MonoOpt.CafHoist`) when
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


{-| Under `mono.validate`, returns the graph unchanged or `Err` with every
violation that
`Compiler.MonoOpt.Staging.checkClosureStaging` finds: a closure or tail
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

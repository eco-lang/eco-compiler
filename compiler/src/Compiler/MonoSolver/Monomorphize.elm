module Compiler.MonoSolver.Monomorphize exposing (monomorphize, monomorphizeWithReport)

{-| The solver-based monomorphizer (Architecture C) — a drop-in replacement for
`Compiler.Monomorphize.Monomorphize`, using the type checker's real HM
unification engine (`Compiler.Type.Unify` / `UnionFind`) instead of the
Dict-substitution engine.

**No fallback.** This engine never consults the original one. A construct it
cannot yet handle returns `Err "MonoSolver.unsupported: <what>"` through the
normal `Result String MonoGraph` channel, which the pipeline surfaces as a loud
build failure. It must NOT import `Compiler.Monomorphize.TypeSubst` or
`.Specialize`, and works only from the total `meta.tipe` (never `meta.tvar`).

The driver mirrors the original phase-for-phase: shared input prep (flags
decoder, MVarId assignment), seed main + flags decoder, LIFO worklist drain, then
assemble and hand off to the shared `Prune.pruneUnreachableSpecs` (which closes
residual number vars and recomputes ctor shapes). Only the per-node
specialization is the new solver engine.

@docs monomorphize

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Id as Id
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), S, WorkItem(..))
import Compiler.MonoSolver.Translate as Translate
import Compiler.MonoSolver.Zonk as Zonk
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Map as DMap
import Data.Set as EverySet
import Dict
import System.TypeCheck.IO as IO


{-| Transform a typed optimized graph into a monomorphized graph, entering from
the named entry point. Same as the original engine plus the LSS knobs (the
original engine never computes sets; `lss.enabled = False` here is
byte-identical to it).
-}
monomorphize : Config.LssConfig -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphize lssConfig entryPointName globalTypeEnv globalGraph =
    Result.map Tuple.first (monomorphizeWithReport lssConfig Config.defaultLimits entryPointName globalTypeEnv globalGraph)


{-| `monomorphize` additionally returning the rendered LSS census
(`Just` iff `lss.report`). The report rides the result because this function
is pure and `compiler/src` cannot use `Debug.toString` — the census is plain
string concatenation, printed to stderr by the Builder.

Also the MONO_030 limits entry point: the Builder passes
`ecoConfig.mono.limits` (env-overridable); the plain `monomorphize` wrapper
defaults them, so test call sites are unchanged.
-}
monomorphizeWithReport : Config.LssConfig -> Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String ( Mono.MonoGraph, Maybe String )
monomorphizeWithReport lssConfig limits entryPointName globalTypeEnv globalGraph =
    let
        ( graphWithFlags, maybeFlagsGlobal ) =
            EntryPrep.insertFlagsDecoderNode entryPointName globalGraph

        ( TOpt.GlobalGraph nodesWithIds _ annotationsWithIds _ _, mvarState ) =
            AssignMVarIds.assignIds graphWithFlags
    in
    case EntryPrep.findEntryPointId entryPointName nodesWithIds of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            let
                mainHome : IO.Canonical
                mainHome =
                    case mainGlobal of
                        TOpt.Global home _ ->
                            home

                s0 : S
                s0 =
                    initState lssConfig limits mainHome nodesWithIds annotationsWithIds globalTypeEnv mvarState

                -- Entry seeding uses an EMPTY super table (matching the original
                -- engine's `entryPointMonoType Dict.empty`).
                mainMonoType : Mono.MonoType
                mainMonoType =
                    Zonk.canTypeToMono Dict.empty mainType

                ( mainSpecId, s1 ) =
                    seedSpec (toptToMonoGlobal mainGlobal) mainMonoType s0

                ( maybeFlagsSpecId, s2 ) =
                    seedFlagsDecoder maybeFlagsGlobal nodesWithIds s1
            in
            case drain s2 of
                Err failure ->
                    Err (renderFailure failure)

                Ok sFinal ->
                    let
                        graph =
                            pruneGraph sFinal (assembleRawGraph sFinal mainSpecId maybeFlagsSpecId)

                        report =
                            if lssConfig.report then
                                Just (renderLssReport sFinal graph)

                            else
                                Nothing
                    in
                    Ok ( graph, report )


{-| The LSS census (design §8.6): member counts, set-size histogram, widening
events by cause, signature memo stats, and the top per-global spec counts.
Rendered post-prune; plain string concatenation only.
-}
renderLssReport : S -> Mono.MonoGraph -> String
renderLssReport sFinal (Mono.MonoGraph g) =
    let
        stats =
            sFinal.lssStats

        lambdaCount =
            Dict.size sFinal.env.lamLabels

        internedCount =
            Dict.size sFinal.lssMemberTable.byKey

        sigCount =
            Dict.size sFinal.lssSignatures

        trivialCount =
            Dict.foldl
                (\_ sig n ->
                    if sig.trivial then
                        n + 1

                    else
                        n
                )
                0
                sFinal.lssSignatures

        histLine =
            if Dict.isEmpty stats.sizeHist then
                "(none)"

            else
                String.join " "
                    (Dict.foldr (\size count acc -> (String.fromInt size ++ "->" ++ String.fromInt count) :: acc) [] stats.sizeHist)

        specCounts =
            Array.foldl
                (\maybeEntry acc ->
                    case maybeEntry of
                        Just ( global, _ ) ->
                            let
                                k =
                                    Mono.toComparableGlobal global
                            in
                            Dict.insert k (1 + Maybe.withDefault 0 (Dict.get k acc)) acc

                        Nothing ->
                            acc
                )
                Dict.empty
                g.registry.reverseMapping

        topSpecs =
            Dict.toList specCounts
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 5
                |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                |> String.join " "

        widenedHistLine =
            if Dict.isEmpty stats.widenedSizeHist then
                "(none)"

            else
                String.join " "
                    (Dict.foldr (\size count acc -> (String.fromInt size ++ "->" ++ String.fromInt count) :: acc) [] stats.widenedSizeHist)

        kernelMissLine =
            if Dict.isEmpty stats.kernelMissHist then
                "(none)"

            else
                Dict.toList stats.kernelMissHist
                    |> List.sortBy (\( _, n ) -> negate n)
                    |> List.take 12
                    |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                    |> String.join " "
    in
    String.join "\n"
        [ "=== LSS census ==="
        , "members: " ++ String.fromInt sFinal.nextMemberId ++ " total (" ++ String.fromInt lambdaCount ++ " source lambdas, " ++ String.fromInt internedCount ++ " interned)"
        , "signatures: " ++ String.fromInt sigCount ++ " memoized (" ++ String.fromInt trivialCount ++ " trivial)"
        , "sets zonked: " ++ String.fromInt stats.setsZonked ++ "; size histogram: " ++ histLine
        , "widened: bySize=" ++ String.fromInt stats.widenedBySize ++ " byKernel=" ++ String.fromInt stats.widenedByKernel ++ " byBudget=" ++ String.fromInt stats.widenedByBudget ++ " bySigSize=" ++ String.fromInt stats.sigStats.widenedBySigSize
        , "widened sizes: " ++ widenedHistLine
        , "join flush: rounds=" ++ String.fromInt stats.joinRounds ++ " retranslations=" ++ String.fromInt stats.retranslations

        -- Substrate census (Phase 1, plans/lss-set-write-substrate.md).
        , "set-writes: skip=" ++ String.fromInt stats.setWriteSkip ++ " flex=" ++ String.fromInt stats.setWriteFlex ++ " topJoin=" ++ String.fromInt stats.setWriteTopJoin ++ " union=" ++ String.fromInt stats.setWriteUnion ++ " slow=" ++ String.fromInt stats.setWriteSlow ++ " slotsMinted=" ++ String.fromInt stats.slotsMinted
        , "joins: identical=" ++ String.fromInt stats.joinIdenticalHit ++ " noop=" ++ String.fromInt stats.joinNoop ++ " changed=" ++ String.fromInt stats.joinChanged ++ " completion=" ++ String.fromInt stats.completionJoins ++ " completionNoop=" ++ String.fromInt stats.completionJoinNoop
        , "devirtDirect=" ++ String.fromInt stats.devirtDirect ++ " devirtKernel=" ++ String.fromInt stats.devirtKernel ++ " unqualifiedLambdaMints=" ++ String.fromInt stats.unqualifiedLambdaMints

        -- LSS_018 monitoring, derived FREE from implementation state at
        -- report time (the per-event fidelity counters were removed after
        -- their one-shot census — Run J: muTied=0 widenedByLet=672
        -- localMultiBypass=469; see plan §7). Meaningful under lss.muTie;
        -- reads 0 flag-off (tables are flag-gated).
        , "muTie: tied=" ++ String.fromInt (Dict.size sFinal.lssMemberTable.muTied) ++ " qualifiedRecorded=" ++ String.fromInt (Dict.size sFinal.lssMemberTable.lambdaQualified)

        -- LSS_019 standalone-member grounding census
        -- (plans/lss-fidelity-2-standalone-member-grounding.md §5):
        -- `deferred` is the residual-arrow precision frontier.
        , "grounding: grounded=" ++ String.fromInt stats.grounding.grounded ++ " deferred=" ++ String.fromInt stats.grounding.deferred

        -- LSS_020 signature-flow census
        -- (plans/lss-fidelity-3-signature-flow-completion.md §B.4):
        -- widenedByCf/kernelFactHits/kernelLicensed are report-gated bumps,
        -- so they read 0 unless ECO_MONO_LSS_REPORT was on for the run.
        -- LSS_022: kernelFactHits counts POSITIONAL row applications and
        -- kernelLicensed counts TypeFaithful pass-throughs — disjoint tiers,
        -- and only the former can also appear in widenedByKernel.
        , "sigflow: widenedByCf=" ++ String.fromInt stats.sigStats.widenedByCf ++ " kernelFactHits=" ++ String.fromInt stats.sigStats.kernelFactHits ++ " kernelLicensed=" ++ String.fromInt stats.sigStats.kernelLicensed ++ " edges=" ++ String.fromInt stats.sigStats.edgesInstalled ++ " degraded=" ++ String.fromInt stats.sigStats.flowDegraded

        -- Census (2026-07-21): E9.2 guard-decline split (declinedKernelCNumber
        -- = the E10.0 `declinedUnsettled` proxy) + the whitelist-growth list.
        , "kernel declines: shape=" ++ String.fromInt stats.declinedKernelShape ++ " cnumber=" ++ String.fromInt stats.declinedKernelCNumber ++ " emission=" ++ String.fromInt stats.declinedKernelEmission ++ " arity=" ++ String.fromInt stats.declinedKernelArity
        , "kernel whitelist misses: " ++ kernelMissLine
        , "kernel licenses REFUSED at the occurrence: "
            ++ (if Dict.isEmpty stats.kernelUnsolvedHist then
                    "(none)"

                else
                    String.join " "
                        (List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
                            (List.sortBy (\( _, v ) -> -v) (Dict.toList stats.kernelUnsolvedHist))
                        )
               )
        , "top specs/global: " ++ topSpecs
        , "=================="
        ]



-- ====== INITIAL STATE ======


initState : Config.LssConfig -> Config.SpecLimits -> IO.Canonical -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> AssignMVarIds.GlobalMVarState -> S
initState lssConfig limits currentModule nodes annotations globalTypeEnv mvarState =
    { worklist = []
    , nodes = Array.empty
    , inProgress = BitSet.empty
    , scheduled = BitSet.empty
    , registry = Registry.emptyRegistry
    , ports = []
    , lambdaCounter = 0
    , superTable = mvarState.superVars
    , nextMVarId = mvarState.nextId
    , lssSignatures = Dict.empty
    , lssInProgress = Dict.empty
    , lssMemberTable = Engine.emptyMemberTable
    , nextMemberId = Id.toComparable mvarState.nextLam
    , lssStats = Engine.emptyLssStats
    , monoMemo = Engine.emptyMonoMemo
    , nodeResolution = Dict.empty
    , intern = Intern.empty
    , env =
        { -- 4c: one O(n) conversion at init (~10-20k globals) buys a
          -- string-build-free probe at every occurrence site. `DMap.foldl`
          -- ignores its ordering argument (Data/Map.elm:240-242); it is passed
          -- for documentation only.
          toptNodes =
            DMap.foldl TOpt.compareGlobal
                (\g node acc -> HashMap.insert TOpt.globalHash (==) g node acc)
                HashMap.empty
                nodes
        , annotations = annotations
        , globalTypeEnv = globalTypeEnv
        , currentModule = currentModule
        , superStatic = mvarState.superVars
        , lss = lssConfig
        , lssKeyedSet = keyedGlobalSet lssConfig.keyedGlobals
        , lamLabels = mvarState.lamLabels
        , limits = limits
        }
    , currentGlobal = Nothing
    , store = Engine.freshStore
    , memo = Dict.empty
    , revMemo = Array.empty
    , varEnv = Dict.empty
    , numberMulti = []
    , localMulti = []
    , derivedDestructors = Dict.empty
    , localCanTypes = Dict.empty

    , dirtySpecs = BitSet.empty
    , dirtyList = []
    , specCountByGlobal = Dict.empty
    , itemAux = Engine.emptyItemAux
    }


{-| E5: parse `lss.keyedGlobals` user entries
(`author/project:Module.Name.value`) into the comparable-gkey set the
`enqueueSpec` gate consults. The comparable shape must match
`Mono.toComparableGlobal`, so build a real `Mono.Global` and key it.
Unparseable entries are skipped (the Builder env override already warned).
-}
keyedGlobalSet : List String -> Dict.Dict String ()
keyedGlobalSet entries =
    List.filterMap parseKeyedGlobal entries
        |> List.map (\g -> ( Mono.toComparableGlobal g, () ))
        |> Dict.fromList


parseKeyedGlobal : String -> Maybe Mono.Global
parseKeyedGlobal entry =
    case String.split ":" entry of
        [ pkg, def ] ->
            case ( String.split "/" pkg, List.reverse (String.split "." def) ) of
                ( [ author, project ], valueName :: revModSegs ) ->
                    if List.isEmpty revModSegs then
                        Nothing

                    else
                        Just
                            (Mono.Global
                                (IO.Canonical ( author, project ) (String.join "." (List.reverse revModSegs)))
                                valueName
                            )

                _ ->
                    Nothing

        _ ->
            Nothing


seedSpec : Mono.Global -> Mono.MonoType -> S -> ( Mono.SpecId, S )
seedSpec global monoType s =
    let
        ( specId, reg1 ) =
            Registry.getOrCreateSpecId global monoType s.registry
    in
    ( specId
    , { s
        | registry = reg1
        , worklist = SpecializeGlobal specId :: s.worklist
        , scheduled = BitSet.insertGrowing specId s.scheduled
      }
    )


seedFlagsDecoder : Maybe TOpt.Global -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> S -> ( Maybe Mono.SpecId, S )
seedFlagsDecoder maybeFlagsGlobal nodes s =
    case maybeFlagsGlobal of
        Nothing ->
            ( Nothing, s )

        Just flagsGlobal ->
            case EntryPrep.findNodeAnnotationType flagsGlobal nodes of
                Nothing ->
                    ( Nothing, s )

                Just decoderTipe ->
                    let
                        decoderMonoType =
                            Zonk.canTypeToMono Dict.empty decoderTipe

                        ( specId, s1 ) =
                            seedSpec (toptToMonoGlobal flagsGlobal) decoderMonoType s
                    in
                    ( Just specId, s1 )



-- ====== WORKLIST DRAIN ======


drain : S -> Result Failure S
drain s =
    case s.worklist of
        [] ->
            -- LSS_010 drain-end flush: specs whose stored types were
            -- annotation-JOINED since their translation re-translate now,
            -- once per ROUND with their fully-joined demands (never once
            -- per join — that cascade was hour-scale on the self-compile).
            -- Each round only exists because some stored type CHANGED, and
            -- joins are monotone in a finite lattice, so rounds terminate;
            -- the cap turns a would-be livelock into a loud EngineBug.
            case s.dirtyList of
                [] ->
                    Ok s

                dirty ->
                    if s.lssStats.joinRounds >= maxJoinRounds then
                        Err
                            (EngineBug
                                ("LSS_010 join flush exceeded "
                                    ++ String.fromInt maxJoinRounds
                                    ++ " rounds ("
                                    ++ String.fromInt (List.length dirty)
                                    ++ " specs still dirty: "
                                    ++ String.join ", "
                                        (List.map
                                            (\sid ->
                                                case Registry.lookupSpecKey sid s.registry of
                                                    Just ( g, _ ) ->
                                                        Mono.toComparableGlobal g ++ "#" ++ String.fromInt sid

                                                    Nothing ->
                                                        "#" ++ String.fromInt sid
                                            )
                                            (List.take 5 dirty)
                                        )
                                    ++ ") — non-monotone join or registry/actualType oscillation"
                                )
                            )

                    else
                        let
                            stats0 =
                                s.lssStats
                        in
                        drain
                            { s
                                | worklist = List.map SpecializeGlobal dirty
                                , dirtyList = []
                                , lssStats = { stats0 | joinRounds = stats0.joinRounds + 1 }
                            }

        (SpecializeGlobal specId) :: rest ->
            case processItem specId { s | worklist = rest } of
                Err e ->
                    Err e

                Ok s1 ->
                    drain s1


{-| LSS_010 flush-round cap. Real programs stabilize in a handful of
rounds (set-flow chain depth); triple digits means something is
oscillating and must fail loudly rather than spin.
-}
maxJoinRounds : Int
maxJoinRounds =
    100


processItem : Mono.SpecId -> S -> Result Failure S
processItem specId s =
    if BitSet.member specId s.inProgress then
        -- Recursive self-reference: already being specialized; drop.
        Ok s

    else if nodeAlreadyDone specId s && not (BitSet.member specId s.dirtySpecs) then
        -- Stale duplicate work item: a LSS_010 re-push already satisfied by a
        -- later (re-)translation, or a duplicate re-push. Flag-off never
        -- reaches this (each spec is pushed exactly once).
        Ok s

    else
        case Registry.lookupSpecKey specId s.registry of
            Nothing ->
                Ok s

            Just ( global, monoType ) ->
                let
                    stats0 =
                        s.lssStats

                    stats1 =
                        if nodeAlreadyDone specId s then
                            { stats0 | retranslations = stats0.retranslations + 1 }

                        else
                            stats0

                    sItemR =
                        Engine.resetItem
                            { s
                                | inProgress = BitSet.insertGrowing specId s.inProgress
                                , currentGlobal = Just global
                                , lssStats = stats1

                                -- LSS_010: consume the dirty mark before
                                -- translating with the (joined) stored type; a
                                -- join arriving DURING this translation re-marks
                                -- it for the next flush round.
                                , dirtySpecs = BitSet.removeGrowing specId s.dirtySpecs
                            }

                    auxR =
                        sItemR.itemAux

                    -- Fix B (LSS_017): expose the spec being translated to the
                    -- lambda-instance member mints. AFTER resetItem — it
                    -- rebuilds itemAux. LSS_018 rides along: the μ-tie scan of
                    -- the STORED demand for qualified members of raw lambdas
                    -- (rebuilt per item, so LSS_010 re-translations re-tie
                    -- against the fully-joined demand — monotone).
                    sItem =
                        { sItemR
                            | itemAux =
                                { auxR
                                    | currentSpecId = Just specId
                                    , demandQualified = demandQualifiedFor monoType sItemR
                                }
                        }
                in
                case global of
                    Mono.Accessor fieldName ->
                        case monoType of
                            Mono.MFunction _ _ [ Mono.MRecord _ fields ] fieldType ->
                                Ok
                                    (finishNode specId
                                        (Mono.MonoTailFunc
                                            [ ( "record", Mono.mRecord fields ) ]
                                            (Mono.MonoRecordAccess (Mono.MonoVarLocal "record" (Mono.mRecord fields)) fieldName fieldType)
                                            monoType
                                        )
                                        sItem
                                    )

                            _ ->
                                Err (EngineBug ("accessor global " ++ fieldName ++ ": expected Mono.mFunction [Mono.mRecord] fieldType"))

                    Mono.Global home name ->
                        let
                            -- D13: resolve the node + its annotation-id set ONCE per
                            -- global (both depend only on the immutable node map), then
                            -- reuse across every spec of the same global. `sItem2`
                            -- carries the memo insert on the first resolve.
                            ( resolution, sItem2 ) =
                                resolveGlobalNode home name sItem
                        in
                        case resolution.node of
                            Nothing ->
                                Ok (finishNode specId (Mono.MonoExtern monoType) sItem2)

                            Just node ->
                                if nodeAlreadyDone specId s && not (nodeSupportsRetranslation node) then
                                    -- LSS_010 latent-bug guard (found by E9): a
                                    -- dirty-flush RE-translation only makes sense
                                    -- for body-bearing nodes. Ctor/enum/box/
                                    -- kernel/manager specs have no set-consuming
                                    -- body, AND their registry type was updated
                                    -- to `nodeType` (the VALUE/result type) at
                                    -- finishNode — feeding that back through
                                    -- `specializeCtorViaScheme`'s whole-scheme
                                    -- unify crashes (arrow vs value). Keep the
                                    -- existing node; the dirty mark was consumed
                                    -- above. Mirror finishNode's bookkeeping
                                    -- (inProgress + currentGlobal) without
                                    -- touching the node.
                                    Ok
                                        (let
                                            aux2 =
                                                sItem2.itemAux
                                         in
                                         { sItem2
                                            | inProgress = BitSet.removeGrowing specId sItem2.inProgress
                                            , currentGlobal = Nothing
                                            , itemAux = { aux2 | currentSpecId = Nothing }
                                         }
                                        )

                                else
                                case specializeNodeSaturating 1 name home node monoType sItem2 of
                                    Err e ->
                                        Err e

                                    Ok ( monoNode0, s1raw ) ->
                                        let
                                            -- Harvest Join-R number taints from this item's store into
                                            -- the global super table before the store is discarded —
                                            -- EXCLUDING the node's own annotation vars (per-spec, memoized).
                                            s1 =
                                                Engine.harvestSuperTableExcept resolution.annIds s1raw

                                            ( monoNode, newLambdaCounter ) =
                                                ResolveAccessorValues.rewriteNode home s1.lambdaCounter monoNode0

                                            actualType =
                                                Mono.nodeType monoNode

                                            -- LSS_010 registry-join invariant (found by
                                            -- E9): for a NON-body node (ctor/enum/box/
                                            -- kernel/manager) `nodeType` is the VALUE/
                                            -- result type, and overwriting the stored
                                            -- FUNCTION-typed demand with it makes every
                                            -- later same-key enqueue mismatch-join —
                                            -- storedChanged oscillates and the flush
                                            -- never converges (and a re-translation
                                            -- would feed the value type to the ctor
                                            -- scheme unify — a crash). Keep the demand
                                            -- for those; body-bearing nodes keep the
                                            -- actualType update they need.
                                            -- Phase 4a: run the completion join
                                            -- ONCE, keeping its changed flag for
                                            -- both the registry write and the
                                            -- census. `Just` exactly when the
                                            -- join site is live (lss on + a
                                            -- body-bearing node).
                                            completionJoin =
                                                if s1.env.lss.enabled && nodeSupportsRetranslation node then
                                                    case Registry.lookupSpecKey specId s1.registry of
                                                        Just ( _, storedT ) ->
                                                            Just (Mono.joinAnnotationsChanged actualType storedT)

                                                        Nothing ->
                                                            Just ( False, actualType )

                                                else
                                                    Nothing

                                            registry2 =
                                                if nodeSupportsRetranslation node then
                                                    -- LSS_010 monotonicity (found by E9): the
                                                    -- registry entry is the JOIN of every
                                                    -- admitted demand's annotations; a plain
                                                    -- actualType overwrite DISCARDS demand-side
                                                    -- members the body's own zonk doesn't carry
                                                    -- (arg-side injected globals), so join-grow /
                                                    -- update-shrink ping-pongs the flush forever
                                                    -- ("registry/actualType oscillation").
                                                    -- Structure from actualType, annos UNIONED
                                                    -- with the stored entry. Flag-off the annos
                                                    -- are all LTop — keep the byte-identical
                                                    -- plain update there.
                                                    --
                                                    -- Phase 4a: the changed flag does NOT gate
                                                    -- this write. `False` means the join result
                                                    -- IS actualType by pointer, but the registry
                                                    -- still holds storedT, so the update must run
                                                    -- either way — the win here is the elided
                                                    -- rebuild, not an elided write.
                                                    case completionJoin of
                                                        Just ( _, joined ) ->
                                                            Registry.updateRegistryType specId joined s1.registry

                                                        Nothing ->
                                                            Registry.updateRegistryType specId actualType s1.registry

                                                else
                                                    s1.registry

                                            s2 =
                                                { s1
                                                    | registry = registry2
                                                    , lambdaCounter = newLambdaCounter
                                                }

                                            -- Phase 1 census: count the joins
                                            -- this site runs (one per completed
                                            -- body-bearing spec). Phase 4a splits
                                            -- out the no-op subset, which the
                                            -- changed flag gives for free:
                                            -- `completion` stays the total.
                                            s3 =
                                                case completionJoin of
                                                    Just ( True, _ ) ->
                                                        Engine.bumpCompletionJoin s2

                                                    Just ( False, _ ) ->
                                                        Engine.bumpCompletionJoinNoop s2

                                                    Nothing ->
                                                        s2
                                        in
                                        Ok (finishNode specId monoNode s3)


{-| LSS_018 (μ-tie): raw-lambda → smallest qualified member id present in the
spec's stored demand type. Consulted by `Engine.lambdaInstanceMemberId` on
routed mints; smallest-id choice makes the canonical family id
deterministic. Built ONLY under `lss.muTie` — the flag-off default path
pays no per-item type walk (the one-shot eligible census, Run J, measured
the population at 0 on the self-compile). The routing predicate is NOT
re-checked here: the map is only ever read after
`lambdaInstanceMemberId`'s own routed check.
-}
demandQualifiedFor : Mono.MonoType -> S -> Dict.Dict Int Int
demandQualifiedFor monoType s =
    if not (s.env.lss.enabled && s.env.lss.muTie) then
        Dict.empty

    else
        List.foldl
            (\mid acc ->
                case Dict.get mid s.lssMemberTable.lambdaQualified of
                    Just ( raw, _ ) ->
                        Dict.update raw
                            (\cur ->
                                Just (min mid (Maybe.withDefault mid cur))
                            )
                            acc

                    Nothing ->
                        acc
            )
            Dict.empty
            (Mono.collectAnnoMembers monoType)


{-| MONO_029 stale-read barrier (R2 of
plans/solver-layout-connectivity-reconciliation.md): translate the item and, if
any recorded CEcoValue residual was read from a var the translation LATER
bound (read-before-saturation), re-translate immediately AGAINST THE SAME
STORE. The item store is monotone — pass 2's zonks see every binding pass 1
made anywhere in the body, so the previously-stale reads come back concrete.
Re-translation must happen here (store in hand), not at the drain-end flush:
`resetItem` would rebuild the store from scratch and deterministically
reproduce the same stale snapshot.

Convergence: each pass only ADDS bindings to one finite store; a pass with no
newly-bound residual reads is a fixpoint. The cap turns oscillation into a
loud EngineBug. Side effects of discarded passes are benign: `enqueueSpec` is
key-idempotent (a spec enqueued under a since-healed erased key may survive as
an unreferenced spec and is pruned), and multi-instance stacks are re-pushed
per pass.
-}
specializeNodeSaturating : Int -> Name -> IO.Canonical -> TOpt.Node TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
specializeNodeSaturating attempt name home node monoType s =
    case specializeNode name home node monoType s of
        Err e ->
            Err e

        Ok ( monoNode, s1 ) ->
            if not (staleResidualRead s1) then
                Ok ( monoNode, s1 )

            else if attempt >= maxSaturationPasses then
                Err
                    (EngineBug
                        ("MONO_029 stale-read saturation exceeded "
                            ++ String.fromInt maxSaturationPasses
                            ++ " passes for "
                            ++ name
                            ++ " — residual reads keep preceding their bindings"
                        )
                    )

            else
                specializeNodeSaturating (attempt + 1) name home node monoType (Engine.clearResidualReads s1)


{-| Stale-read re-translation cap. One extra pass suffices for the observed
shapes (a destructure recorded before a later app-shape unification); anything
deeper indicates reads and bindings chasing each other and must fail loudly.
-}
maxSaturationPasses : Int
maxSaturationPasses =
    5


{-| Specialize one top-level node. `name`/`home` identify the definition (used
for ctor tags and to follow links to their target's name/home).
-}
specializeNode : Name -> IO.Canonical -> TOpt.Node TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
specializeNode name home node monoType s =
    case node of
        TOpt.Define expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.TrackedDefine _ expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.Kernel _ _ ->
            Ok ( Mono.MonoExtern monoType, s )

        TOpt.Ctor index arity canType ->
            Engine.runStep (Translate.specializeCtorViaScheme name (CtorTag.effective home name index) arity canType monoType) s

        TOpt.Enum index canType ->
            Engine.runStep (Translate.enumNode (CtorTag.effective home name index) canType monoType) s

        TOpt.Box canType ->
            -- @unbox single-field type: a 1-field ctor with literal tag 0.
            Engine.runStep (Translate.specializeCtorViaScheme name 0 1 canType monoType) s

        TOpt.Link linkedGlobal ->
            case HashMap.get TOpt.globalHash (==) linkedGlobal s.env.toptNodes of
                Nothing ->
                    Ok ( Mono.MonoExtern monoType, s )

                Just linkedNode ->
                    case linkedGlobal of
                        TOpt.Global linkedHome linkedName ->
                            specializeNode linkedName linkedHome linkedNode monoType s

        TOpt.Manager _ ->
            case home of
                IO.Canonical _ modName ->
                    Ok ( Mono.MonoManagerLeaf (Name.toElmString modName) monoType, s )

        TOpt.Cycle _ valueDefs funcDefs _ ->
            -- The demand reaches the cycle node through a `_M$<first>` Link, so
            -- `name` here is the group name; the REQUESTED member is the original
            -- demand preserved in `currentGlobal`. Each member's cross-references
            -- enqueue its siblings, so members materialize as separate work items.
            let
                reqName =
                    case s.currentGlobal of
                        Just (Mono.Global _ n) ->
                            n

                        _ ->
                            name
            in
            Engine.runStep (Translate.specializeCycle reqName valueDefs funcDefs monoType) s

        TOpt.PortIncoming expr _ meta ->
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    Engine.runStep (Translate.specializePort True expr meta.tipe monoType) s

                _ ->
                    -- The same port Global demanded at its DECODER (non-function)
                    -- type: compile the payload decoder as a plain value node
                    -- (mirrors the original engine's split).
                    defineFrom (TOpt.typeOf expr) expr monoType s

        TOpt.PortOutgoing expr _ meta ->
            Engine.runStep (Translate.specializePort False expr meta.tipe monoType) s


{-| D13: resolve a `Mono.Global` to its `TOpt.Node` and annotation-id set, memoized
by the comparable global. The node map and `nodeAnnotationIds` are both functions
of the immutable `toptNodes`, so a global with N specializations resolves once and
the DMap descent + `freeVarIds` walk are skipped for the other N-1. The memo lives
in `S.nodeResolution` (survives `resetItem`); byte-identical to recomputing.
-}
resolveGlobalNode : IO.Canonical -> Name -> S -> ( Engine.NodeResolution, S )
resolveGlobalNode home name s =
    let
        gkey =
            TOpt.toComparableGlobal (TOpt.Global home name)
    in
    case Dict.get gkey s.nodeResolution of
        Just resolution ->
            ( resolution, s )

        Nothing ->
            let
                node =
                    HashMap.get TOpt.globalHash (==) (TOpt.Global home name) s.env.toptNodes

                annIds =
                    case node of
                        Just n ->
                            nodeAnnotationIds n

                        Nothing ->
                            EverySet.empty

                resolution =
                    { node = node, annIds = annIds }
            in
            ( resolution, { s | nodeResolution = Dict.insert gkey resolution s.nodeResolution } )


{-| The item node's annotation free-var ids (excluded from taint harvest).
-}
nodeAnnotationIds : TOpt.Node TypeIds.MVarId -> EverySet.EverySet Int Int
nodeAnnotationIds node =
    let
        fromCan t =
            EverySet.fromList identity (List.map Id.toComparable (KernelAbi.freeVarIds t []))
    in
    case node of
        TOpt.Define _ _ meta ->
            fromCan meta.tipe

        TOpt.TrackedDefine _ _ _ meta ->
            fromCan meta.tipe

        _ ->
            EverySet.empty


{-| Specialize a value definition: assert the demanded type against the def's
annotation in the store (so a polymorphic body concretizes via the shared memo),
then translate the body. For a monomorphic global the demand equals the
annotation and the unification is a no-op.
-}
defineFrom : Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
defineFrom annCanType expr demand s =
    case Engine.runStep (Translate.demandUnifyRoot annCanType demand expr) s of
        Err e ->
            Err e

        Ok ( (), s1 ) ->
            case Engine.runStep (Translate.translate expr) s1 of
                Err e ->
                    Err e

                Ok ( monoExpr, s2 ) ->
                    Ok ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s2 )


{-| LSS_010 re-translation eligibility: only body-bearing nodes can be
meaningfully re-translated with a joined demand. Ctor/enum/box/kernel/
manager specs are shape-derived — and their registry type is rewritten to
the node's VALUE type at finishNode, which the ctor-scheme unify rejects.
Links chase to their target's kind.
-}
nodeSupportsRetranslation : TOpt.Node TypeIds.MVarId -> Bool
nodeSupportsRetranslation node =
    case node of
        TOpt.Define _ _ _ ->
            True

        TOpt.TrackedDefine _ _ _ _ ->
            True

        TOpt.Cycle _ _ _ _ ->
            True

        TOpt.PortIncoming _ _ _ ->
            True

        TOpt.PortOutgoing _ _ _ ->
            True

        TOpt.Link _ ->
            -- The linked target is Define/Cycle in practice; allowing the
            -- chase is safe (specializeNode recurses into the target).
            True

        _ ->
            False


finishNode : Mono.SpecId -> Mono.MonoNode -> S -> S
finishNode specId monoNode s =
    -- A join that landed mid-translation left the spec's dirty mark set;
    -- the drain-end flush re-pushes it (LSS_010) — no per-item re-push.
    let
        aux =
            s.itemAux
    in
    { s
        | nodes = arraySetGrowing specId (Just monoNode) s.nodes
        , inProgress = BitSet.removeGrowing specId s.inProgress
        , currentGlobal = Nothing

        -- Fix B (LSS_017): a mint outside any item must not silently adopt a
        -- stale spec — clear alongside currentGlobal.
        , itemAux = { aux | currentSpecId = Nothing }
    }


{-| Did any recorded CEcoValue residual read become resolvable after the fact?
Point-based reads (`ecoResidualReads`) are stale only when (a) the var's class
is now bound (structure/alias — or a Number super that Prune would close to
MInt) AND (b) the class is UF-equivalent to the ITEM MEMO's point for the
var's canonical id — i.e. the shared canonical family. Isolated per-call
instantiations (loadType with a fresh memo, the SKI/per-call-site design) are
read-free-then-bound on EVERY pass by construction; treating them as stale
livelocks the saturation loop (R0 census finding, RecordNarrow corpus).
Key-based reads (`ecoResidualKeyReads`) are vars that had not entered the
store when classified; they are stale only if the memo has since gained a
BOUND point for them.
-}
staleResidualRead : S -> Bool
staleResidualRead s =
    List.any (staleVarRead s) s.itemAux.ecoResidualReads
        || List.any
            (\key ->
                case Dict.get key s.memo of
                    Just pt ->
                        varResolvedNow s.store pt

                    Nothing ->
                        False
            )
            s.itemAux.ecoResidualKeyReads


staleVarRead : S -> IO.Variable -> Bool
staleVarRead s var =
    varResolvedNow s.store var
        && (case Maybe.andThen identity (Array.get (Engine.pointKey var) s.revMemo) of
                Nothing ->
                    False

                Just mid ->
                    case Dict.get (Engine.mvarIdKey mid) s.memo of
                        Nothing ->
                            False

                        Just memoPoint ->
                            let
                                ( _, eq ) =
                                    UF.equivalent memoPoint var s.store
                            in
                            eq
           )


varResolvedNow : IO.State -> IO.Variable -> Bool
varResolvedNow store var =
    let
        ( _, desc ) =
            UF.get var store
    in
    case desc.content of
        IO.Structure _ ->
            True

        IO.Alias _ _ _ _ ->
            True

        IO.FlexSuper IO.Number _ ->
            True

        IO.RigidSuper IO.Number _ ->
            True

        _ ->
            False


nodeAlreadyDone : Mono.SpecId -> S -> Bool
nodeAlreadyDone specId s =
    case Array.get specId s.nodes of
        Just (Just _) ->
            True

        _ ->
            False



-- ====== ASSEMBLY (mirror of assembleRawGraphFrom) ======


assembleRawGraph : S -> Mono.SpecId -> Maybe Mono.SpecId -> Mono.MonoGraph
assembleRawGraph s mainSpecId flagsDecoderSpecId =
    let
        nextId : Int
        nextId =
            s.registry.nextId

        nodesArray : Array (Maybe Mono.MonoNode)
        nodesArray =
            let
                currentLen =
                    Array.length s.nodes
            in
            if currentLen >= nextId then
                s.nodes

            else
                Array.append s.nodes (Array.repeat (nextId - currentLen) Nothing)

        ( callEdgesArray, specHasEffects, specValueUsed ) =
            Array.foldl
                (\maybeNode ( specId, ( edgesAcc, effectsAcc, valueUsedAcc ) ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, ( edgesAcc, effectsAcc, valueUsedAcc ) )

                        Just node ->
                            let
                                -- D14: one fused walk yields both the call-edges and
                                -- the effects flag (was two full `foldExpr` passes over
                                -- the same expr). Byte-identical: same traversal order,
                                -- same cons order for edges, same Debug-kernel effect.
                                ( neighbors, hasEffects ) =
                                    collectEdgesAndEffectsFromNode node

                                newEdges =
                                    Array.set specId (Just neighbors) edgesAcc

                                newEffects =
                                    if hasEffects then
                                        BitSet.insertGrowing specId effectsAcc

                                    else
                                        effectsAcc

                                newValueUsed =
                                    List.foldl (\calleeId acc -> BitSet.insertGrowing calleeId acc) valueUsedAcc neighbors
                            in
                            ( specId + 1, ( newEdges, newEffects, newValueUsed ) )
                )
                ( 0, ( Array.repeat nextId Nothing, BitSet.empty, BitSet.empty ) )
                nodesArray
                |> Tuple.second

        valueUsedWithMain : BitSet.BitSet
        valueUsedWithMain =
            BitSet.insertGrowing mainSpecId specValueUsed
    in
    Mono.MonoGraph
        { nodes = nodesArray
        , registry = { nextId = nextId, mapping = Mono.specKeyMapEmpty, reverseMapping = s.registry.reverseMapping, countByGlobal = Dict.empty }
        , main = Just (Mono.StaticMain mainSpecId)
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = s.lambdaCounter
        , callEdges = callEdgesArray
        , specHasEffects = specHasEffects
        , specValueUsed = valueUsedWithMain
        , ports = s.ports
        , flagsDecoder = flagsDecoderSpecId
        , lssMemberOrigins = buildMemberOrigins s.env.toptNodes s.lssMemberTable
        , lssBlockedMembers = s.lssMemberTable.muTied
        }


{-| B3.5: invert `LssMemberTable.byKey` into member-id → origin, dispatching on
the 2-char key prefix (`g|`/`c|`/`k|`/`a|`; `l|` lambdas are skipped — resolved
via the instance index). TOpt.Global payloads convert to Mono.Global here (the
origin carries Monomorphized's own Global; this site imports TOpt).
-}
buildMemberOrigins : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> Engine.LssMemberTable -> Dict.Dict Int Mono.MemberOrigin
buildMemberOrigins toptNodes table =
    Dict.foldl
        (\key mid acc ->
            case String.left 2 key of
                "g|" ->
                    case Dict.get mid table.sources of
                        Just (Engine.SourceGlobal g) ->
                            Dict.insert mid (globalOrigin toptNodes g) acc

                        _ ->
                            acc

                "c|" ->
                    case Dict.get mid table.sources of
                        Just (Engine.SourceGlobal g) ->
                            Dict.insert mid (Mono.OriginCtor (toptToMono g)) acc

                        _ ->
                            acc

                "k|" ->
                    case Dict.get mid table.sources of
                        Just (Engine.SourceKernel ( _, home, name )) ->
                            Dict.insert mid (Mono.OriginKernel home name) acc

                        _ ->
                            acc

                "a|" ->
                    Dict.insert mid (Mono.OriginAccessor (String.dropLeft 2 key)) acc

                _ ->
                    acc
        )
        Dict.empty
        table.byKey


{-| F-5A: a `g|` member whose node IS a constructor gets `OriginCtor`.

Only nullary-enum and box constructors are minted under `c|`
(`TypedOptimized.elm:155-156` — `VarEnum` / `VarBox`); every other
constructor — `Just`, `List.::`, any user-defined unary ctor — canonicalizes
to a `TOpt.VarGlobal` and lands under `g|`. Consumers read the origin to
decide whether a member's evaluation can reach `Debug`, and CONSTRUCTING a
value never can, so the key prefix must not be the answer.

Link-chased, and eta-free ctor ALIASES are chased through their `Define`
body: without that, `let w = Wrap in List.map w` declines while
`List.map Wrap` licenses — an asymmetry with no explanation in the census.
Depth-bounded so a malformed `Link` cycle cannot hang the compiler.
(`LssInfer.kernelAliasOf` is the same pattern, but it runs against `Engine.S`
and is not importable here.)

-}
globalOrigin : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.Global -> Mono.MemberOrigin
globalOrigin toptNodes g =
    if ctorBackedGlobal toptNodes 8 g then
        Mono.OriginCtor (toptToMono g)

    else
        Mono.OriginGlobal (toptToMono g)


ctorBackedGlobal : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> Int -> TOpt.Global -> Bool
ctorBackedGlobal toptNodes fuel g =
    if fuel <= 0 then
        False

    else
        case HashMap.get TOpt.globalHash (==) g toptNodes of
            Just (TOpt.Ctor _ _ _) ->
                True

            Just (TOpt.Box _) ->
                True

            Just (TOpt.Link target) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.Define (TOpt.VarBox _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.Define (TOpt.VarGlobal _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.TrackedDefine _ (TOpt.VarBox _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.TrackedDefine _ (TOpt.VarGlobal _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            _ ->
                False


toptToMono : TOpt.Global -> Mono.Global
toptToMono (TOpt.Global h n) =
    Mono.Global h n


pruneGraph : S -> Mono.MonoGraph -> Mono.MonoGraph
pruneGraph s rawGraph =
    Prune.pruneUnreachableSpecs
        (State.initMVarEnv s.nextMVarId s.superTable)
        s.env.globalTypeEnv
        rawGraph



-- ====== CALL-EDGE / EFFECT COLLECTION (mirror of the original private helpers) ======


{-| D14: fused edge-and-effect step. One `foldExpr` pass accumulates both the
call-edge spec ids (a `MonoVarGlobal`, cons order preserved) and the effects flag
(a `Debug` kernel reference). Replaces the former `extractSpecId` + `checkExpr`
double walk over the same expr; each expr node contributes to at most one field,
so the union is exact and byte-identical.
-}
collectEdgesAndEffects : Mono.MonoExpr -> ( List Int, Bool ) -> ( List Int, Bool )
collectEdgesAndEffects expr (( edges, effects ) as acc) =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            ( specId :: edges, effects )

        Mono.MonoVarKernel _ _ "Debug" _ _ ->
            ( edges, True )

        _ ->
            acc


collectEdgesAndEffectsFromNode : Mono.MonoNode -> ( List Int, Bool )
collectEdgesAndEffectsFromNode node =
    case node of
        Mono.MonoDefine expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoTailFunc _ expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoPortIncoming expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoPortOutgoing expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        _ ->
            ( [], False )



-- ====== HELPERS ======


toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


arraySetGrowing : Int -> Maybe a -> Array (Maybe a) -> Array (Maybe a)
arraySetGrowing index value arr =
    let
        len =
            Array.length arr
    in
    if index < len then
        Array.set index value arr

    else
        Array.set index value (Array.append arr (Array.repeat (index - len + 1) Nothing))


renderFailure : Failure -> String
renderFailure failure =
    case failure of
        Unsupported msg ->
            "MonoSolver.unsupported: " ++ msg

        UnifyMismatch msg ->
            "MonoSolver.unify-mismatch: " ++ msg

        EngineBug msg ->
            "MonoSolver.bug: " ++ msg

        LimitExceeded msg ->
            -- MONO_030: a resource watchdog, deliberately NOT framed as a
            -- compiler bug — the message itself names the limit, the env
            -- var, and the likely cause (poly-rec via annotated mutual
            -- cycles is legal Elm).
            msg

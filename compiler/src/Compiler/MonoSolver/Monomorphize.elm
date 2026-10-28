module Compiler.MonoSolver.Monomorphize exposing
    ( monomorphize
    , monomorphizeWithReport, monomorphizeWithReportAssigned
    )

{-| The driver of the solver-based monomorphizer: it turns a typed optimized
program graph into a monomorphized one, in which every function is used at one
concrete type.

Monomorphization proceeds one work item at a time, as
`Compiler.MonoSolver.Engine` describes: a work item is one _spec_, a global at
one concrete `MonoType`, named by a `SpecId` in the specialization registry.
This module creates the first specs, for the entry point and for its flags
decoder when it has one, and drains the worklist, handing each item's node to
`Compiler.MonoSolver.Translate`. Translating an item can create and schedule
further specs. When the worklist is empty the graph is assembled from the
translated nodes and passed to `Prune.pruneUnreachableSpecs`, which drops the
specs no root reaches (the entry point, the flags decoder and every incoming
port's decoder) and closes the remaining number variables.

Most failures do not come back through the `Result`. A construct the engine
cannot translate, or a failed unification, aborts the process through
`Engine.crashFailure`. The `Err` cases are: no entry point of the given name; a
spec watchdog trip (the limits in `Config.SpecLimits`), reported once the item
that tripped it has finished; and three broken invariants of this module, each
an `EngineBug`: too many flush rounds, too many saturation passes, and an
accessor spec whose type is not a function of one record.

Two loops translate again. A _saturation pass_ translates one item again
against the same store, when a read-back that gave an erased type variable
turns out to have been made before that variable was bound, later in the same
item; the next pass reads the binding. A _flush round_ starts when the
worklist is empty but some specs are _dirty_: with lambda-set specialization
(LSS) on, a spec's stored type is the join of every demand made for it, and a
spec whose stored type grew after it was scheduled is translated again with
the joined type. Each loop has a cap, past which it fails with an `Err`.

With LSS on, function types carry lambda sets (see `Compiler.MonoSolver.Engine`).
After the drain, four _settle passes_ rewrite registry types, filling set
variables (`LVar`) and ⊤ annotations from evidence elsewhere in the registry or
in the translated closures. They run after the drain because only then has
every spec contributed, so a union over all of them covers every value that can
reach a position; a union taken earlier could leave out a construction not yet
translated. Their order matters: `settleVarCtorRows` reads the ⊤ annotations
that `settleCtorRows` then fills, and the second `settleVarSuccessors` extends
sets that `settleVarLambda` writes. With LSS off every settle pass returns its
input.

The settle passes and the census name an arrow inside a type by its _position
path_: `/aN` is the Nth argument of a function, `/r` its result, `/l` a list
element, `/tN` a tuple element, `/f:name` a record field and `/cN` a custom-type
argument, and the empty path is the type itself. A _cell_ (`VarCell`, and the
records the settle passes build alike) gathers what several types hold at one
path: whether any has ⊤, whether any has a set that is not known, and the union
of the sets.

Nearly half of the file is `renderLssReport`, which renders census counters as
text when `lss.report` is on. It reads the final state and the pruned graph and
changes neither.

@docs monomorphize
@docs monomorphizeWithReport, monomorphizeWithReportAssigned

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Id as Id
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), S, WorkItem(..))
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.MonoSolver.LssInfer as LssInfer
import Compiler.MonoSolver.Store as Store
import Compiler.MonoSolver.Translate as Translate
import Compiler.MonoSolver.Zonk as Zonk
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Map as DMap
import Data.Set as EverySet
import Dict
import System.TypeCheck.IO as IO


{-| Returns the monomorphized graph of `globalGraph`, entered from the
definition named `entryPointName`, as `monomorphizeWithReportAssigned`
describes, with the default spec limits and without the census text.
-}
monomorphize : Config.LssConfig -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphize lssConfig entryPointName globalTypeEnv globalGraph =
    Result.map Tuple.first (monomorphizeWithReport lssConfig Config.defaultLimits entryPointName globalTypeEnv globalGraph)


{-| Returns what `monomorphizeWithReportAssigned` returns for a graph whose ids
have not been assigned yet. It first runs `EntryPrep.assign`, with solver roots
on, and with the stamping census on exactly when `lss.arrowCensus` is.
-}
monomorphizeWithReport : Config.LssConfig -> Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String ( Mono.MonoGraph, Maybe String )
monomorphizeWithReport lssConfig limits entryPointName globalTypeEnv globalGraph =
    monomorphizeWithReportAssigned lssConfig
        limits
        entryPointName
        globalTypeEnv
        (EntryPrep.assign ( True, lssConfig.arrowCensus ) entryPointName globalGraph)


{-| Returns the monomorphized graph of an id-assigned graph, entered from the
definition named `entryPointName` that `EntryPrep.findEntryPointId` finds (in
the root module `assigned.entryHome` when that is given),
together with the LSS census text, which is `Just` exactly when `lss.report` is
on.

The entry point, and the flags decoder `assigned` carries when the entry is a
`Program`, are seeded as specs at their annotation types, read with an empty
super table. The result is `Err` when no definition has that name, or when the
drain fails as the module docstring describes.

-}
monomorphizeWithReportAssigned : Config.LssConfig -> Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String ( Mono.MonoGraph, Maybe String )
monomorphizeWithReportAssigned lssConfig limits entryPointName globalTypeEnv assigned =
    let
        (TOpt.GlobalGraph nodesWithIds _ annotationsWithIds _ _) =
            assigned.graph

        maybeFlagsGlobal =
            assigned.flagsGlobal

        mvarState =
            assigned.mvarState
    in
    case EntryPrep.findEntryPointId assigned.entryHome entryPointName nodesWithIds of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            let
                mainHome : ModuleName.Canonical
                mainHome =
                    case mainGlobal of
                        TOpt.Global home _ ->
                            home

                s0 : S
                s0 =
                    initState lssConfig limits mainHome nodesWithIds annotationsWithIds globalTypeEnv mvarState

                mainMonoType : Mono.MonoType
                mainMonoType =
                    Zonk.canTypeToMono Dict.empty mainType

                -- Seeds bypass `Engine.enqueueSpec`, so their own spine is stamped here.
                ( mainSpecId, s1 ) =
                    case Translate.stampSelfSpine mainGlobal mainMonoType s0 of
                        ( stampedMain, s0b ) ->
                            seedSpec (toptToMonoGlobal mainGlobal) stampedMain s0b

                ( maybeFlagsSpecId, s2 ) =
                    seedFlagsDecoder maybeFlagsGlobal nodesWithIds s1
            in
            case drain s2 of
                Err failure ->
                    Err (Engine.renderFailure failure)

                Ok sDrained ->
                    let
                        -- The order of the settle passes matters; see the module docstring.
                        sFinal =
                            settleVarSuccessors
                                (settleVarLambda
                                    (settleVarSuccessors (settleCtorRows (settleVarCtorRows sDrained)))
                                )

                        graph =
                            pruneGraph sFinal (assembleRawGraph sFinal mainSpecId maybeFlagsSpecId)

                        report =
                            if lssConfig.report then
                                Just (renderLssReport sFinal graph)

                            else
                                Nothing
                    in
                    Ok ( graph, report )


{-| Returns the state with every constructor row of the registry that carries a
⊤ enriched from the other rows of the same constructor. Does nothing with LSS
off.

A constructor row is a registry entry whose global is a `Ctor` or `Box` node.
For each constructor, all of its rows are first folded into one type with
`Mono.enrichAnnotations`, so the sets at one position are united and a ⊤ or set
variable gives way to a set another row has there. Each row carrying a ⊤
anywhere is then enriched from that union with `Mono.enrichAnnotationsTopOnly`,
which replaces a ⊤ with the union's set where the union has one, adds the
union's members to `LPartial` and set annotations, a set becoming an `LPartial`
where the union is one, and leaves every `LVar` alone; set variables are `settleVarCtorRows`'s concern. One sweep is
enough, because every union is computed before any row is rewritten.

-}
settleCtorRows : S -> S
settleCtorRows s =
    if not s.env.lss.enabled then
        s

    else
        let
            isCtorGlobal key =
                case key of
                    Mono.Global scHome scName ->
                        case HashMap.get TOpt.globalHash (==) (TOpt.Global scHome scName) s.env.toptNodes of
                            Just (TOpt.Ctor _ _ _) ->
                                True

                            Just (TOpt.Box _) ->
                                True

                            _ ->
                                False

                    _ ->
                        False

            gkeyOf key =
                case key of
                    Mono.Global scHome scName ->
                        Mono.toComparableGlobal (Mono.Global scHome scName)

                    _ ->
                        "?"

            unions =
                Array.foldl
                    (\entry acc ->
                        case entry of
                            Just ( key, monoType ) ->
                                if isCtorGlobal key then
                                    Dict.update (gkeyOf key)
                                        (\v ->
                                            Just
                                                (case v of
                                                    Just u ->
                                                        Mono.enrichAnnotations u monoType

                                                    Nothing ->
                                                        monoType
                                                )
                                        )
                                        acc

                                else
                                    acc

                            Nothing ->
                                acc
                    )
                    Dict.empty
                    s.registry.reverseMapping

            registry1 =
                Tuple.second
                    (Array.foldl
                        (\entry ( idx, reg ) ->
                            case entry of
                                Just ( key, monoType ) ->
                                    if isCtorGlobal key && Mono.hasTopAnno monoType then
                                        case Dict.get (gkeyOf key) unions of
                                            Just u ->
                                                let
                                                    enriched =
                                                        Mono.enrichAnnotationsTopOnly monoType u
                                                in
                                                if enriched == monoType then
                                                    ( idx + 1, reg )

                                                else
                                                    ( idx + 1, Registry.updateRegistryType idx enriched reg )

                                            Nothing ->
                                                ( idx + 1, reg )

                                    else
                                        ( idx + 1, reg )

                                Nothing ->
                                    ( idx + 1, reg )
                        )
                        ( 0, s.registry )
                        s.registry.reverseMapping
                    )
        in
        { s | registry = registry1 }


{-| Returns the state with set variables in the constructor rows of the
registry replaced by the union of the sets the constructor's rows hold at the
same position, where those rows show the union is complete. Does nothing with
LSS off.

A constructor row is a registry entry whose global is a `Ctor` or `Box` node.
For each constructor, a cell is gathered at every position path over all of its
rows. Rows of one constructor can differ in shape, so cells are keyed by path
rather than by walking two types in step, and a ⊤ in a row of another shape
still reaches the cell. A cell is contaminated by a ⊤, by an `LPartial` (a
lower bound, so other members may exist), or by an `LVar` in a row whose spec
is in `flexCtorSpecs`, the constructions whose argument carried an unresolved
arrow. An `LVar` in an unmarked row contaminates nothing. An `LVar` is replaced
by its cell's union only when the cell is not contaminated and has seen a set.

Cells are keyed by the constructor's name and the path, without the module, so
constructors of the same name in different modules share cells.

The numbers of writes and of each kind of skip go to the census, and the writes
also by module.

-}
settleVarCtorRows : S -> S
settleVarCtorRows s =
    if not s.env.lss.enabled then
        s

    else
        let
            isCtorGlobal key =
                case key of
                    Mono.Global vcHome vcName ->
                        case HashMap.get TOpt.globalHash (==) (TOpt.Global vcHome vcName) s.env.toptNodes of
                            Just (TOpt.Ctor _ _ _) ->
                                True

                            Just (TOpt.Box _) ->
                                True

                            _ ->
                                False

                    _ ->
                        False

            gkeyOf key =
                case key of
                    Mono.Global _ vcName ->
                        vcName

                    _ ->
                        "?"

            moduleOf key =
                case key of
                    Mono.Global (ModuleName.Canonical _ vcModule) _ ->
                        vcModule

                    _ ->
                        "?"

            emptyCell =
                { top = False, flexVar = False, sets = Nothing }

            collectCell marked anno cell =
                case anno of
                    Mono.LTop _ ->
                        { cell | top = True }

                    Mono.LSet ms ->
                        { cell | sets = Just (Mono.unionSortedInts ms (Maybe.withDefault [] cell.sets)) }

                    -- A lower bound: the value may hold members it does not list.
                    Mono.LPartial _ ->
                        { cell | flexVar = True }

                    Mono.LVar _ ->
                        if marked then
                            { cell | flexVar = True }

                        else
                            cell

            collectWalk marked gname path t acc =
                case t of
                    Mono.MFunction _ anno args result ->
                        let
                            acc1 =
                                Dict.update (gname ++ "|" ++ path)
                                    (\v -> Just (collectCell marked anno (Maybe.withDefault emptyCell v)))
                                    acc

                            accR =
                                collectWalk marked gname (path ++ "/r") result acc1
                        in
                        List.foldl
                            (\( i, a ) accA -> collectWalk marked gname (path ++ "/a" ++ String.fromInt i) a accA)
                            accR
                            (List.indexedMap Tuple.pair args)

                    Mono.MList _ inner ->
                        collectWalk marked gname (path ++ "/l") inner acc

                    Mono.MTuple _ elems ->
                        List.foldl
                            (\( i, e ) accE -> collectWalk marked gname (path ++ "/t" ++ String.fromInt i) e accE)
                            acc
                            (List.indexedMap Tuple.pair elems)

                    Mono.MRecord _ fields ->
                        Dict.foldl (\fname ft a -> collectWalk marked gname (path ++ "/f:" ++ fname) ft a) acc fields

                    Mono.MCustom _ _ _ args ->
                        List.foldl
                            (\( i, a ) accA -> collectWalk marked gname (path ++ "/c" ++ String.fromInt i) a accA)
                            acc
                            (List.indexedMap Tuple.pair args)

                    _ ->
                        acc

            cells =
                Tuple.second
                    (Array.foldl
                        (\entry ( idx, acc ) ->
                            case entry of
                                Just ( key, monoType ) ->
                                    if isCtorGlobal key then
                                        ( idx + 1
                                        , collectWalk (Dict.member idx s.lssStats.flexCtorSpecs)
                                            (gkeyOf key)
                                            ""
                                            monoType
                                            acc
                                        )

                                    else
                                        ( idx + 1, acc )

                                Nothing ->
                                    ( idx + 1, acc )
                        )
                        ( 0, Dict.empty )
                        s.registry.reverseMapping
                    )

            rewriteWalk gname path t st =
                case t of
                    Mono.MFunction _ anno args result ->
                        let
                            ( args1, st1 ) =
                                List.foldr
                                    (\( i, a ) ( accL, accSt ) ->
                                        let
                                            ( a1, accSt1 ) =
                                                rewriteWalk gname (path ++ "/a" ++ String.fromInt i) a accSt
                                        in
                                        ( a1 :: accL, accSt1 )
                                    )
                                    ( [], st )
                                    (List.indexedMap Tuple.pair args)

                            ( result1, st2 ) =
                                rewriteWalk gname (path ++ "/r") result st1

                            ( anno1, st3 ) =
                                case anno of
                                    Mono.LVar _ ->
                                        case Dict.get (gname ++ "|" ++ path) cells of
                                            Just cell ->
                                                if cell.top then
                                                    ( anno, { st2 | skipTop = st2.skipTop + 1 } )

                                                else if cell.flexVar then
                                                    ( anno, { st2 | skipFlexVar = st2.skipFlexVar + 1 } )

                                                else
                                                    case cell.sets of
                                                        Just union ->
                                                            ( Mono.LSet union, { st2 | wrote = st2.wrote + 1 } )

                                                        Nothing ->
                                                            ( anno, { st2 | skipNoInfo = st2.skipNoInfo + 1 } )

                                            Nothing ->
                                                ( anno, { st2 | skipNoInfo = st2.skipNoInfo + 1 } )

                                    _ ->
                                        ( anno, st2 )
                        in
                        ( Mono.mFunction anno1 args1 result1, st3 )

                    Mono.MList _ inner ->
                        let
                            ( inner1, st1 ) =
                                rewriteWalk gname (path ++ "/l") inner st
                        in
                        ( Mono.mList inner1, st1 )

                    Mono.MTuple _ elems ->
                        let
                            ( elems1, st1 ) =
                                List.foldr
                                    (\( i, e ) ( accL, accSt ) ->
                                        let
                                            ( e1, accSt1 ) =
                                                rewriteWalk gname (path ++ "/t" ++ String.fromInt i) e accSt
                                        in
                                        ( e1 :: accL, accSt1 )
                                    )
                                    ( [], st )
                                    (List.indexedMap Tuple.pair elems)
                        in
                        ( Mono.mTuple elems1, st1 )

                    Mono.MRecord _ fields ->
                        let
                            ( fields1, st1 ) =
                                Dict.foldl
                                    (\fname ft ( accD, accSt ) ->
                                        let
                                            ( ft1, accSt1 ) =
                                                rewriteWalk gname (path ++ "/f:" ++ fname) ft accSt
                                        in
                                        ( Dict.insert fname ft1 accD, accSt1 )
                                    )
                                    ( Dict.empty, st )
                                    fields
                        in
                        ( Mono.mRecord fields1, st1 )

                    Mono.MCustom _ vcHome vcName args ->
                        let
                            ( args1, st1 ) =
                                List.foldr
                                    (\( i, a ) ( accL, accSt ) ->
                                        let
                                            ( a1, accSt1 ) =
                                                rewriteWalk gname (path ++ "/c" ++ String.fromInt i) a accSt
                                        in
                                        ( a1 :: accL, accSt1 )
                                    )
                                    ( [], st )
                                    (List.indexedMap Tuple.pair args)
                        in
                        ( Mono.mCustom vcHome vcName args1, st1 )

                    _ ->
                        ( t, st )

            ( registry1, totals ) =
                Tuple.second
                    (Array.foldl
                        (\entry ( idx, ( reg, tAcc ) ) ->
                            case entry of
                                Just ( key, monoType ) ->
                                    if isCtorGlobal key then
                                        let
                                            ( rewritten, stEnd ) =
                                                rewriteWalk (gkeyOf key)
                                                    ""
                                                    monoType
                                                    { wrote = 0, skipTop = 0, skipFlexVar = 0, skipNoInfo = 0 }

                                            tAcc1 =
                                                { wrote = tAcc.wrote + stEnd.wrote
                                                , skipTop = tAcc.skipTop + stEnd.skipTop
                                                , skipFlexVar = tAcc.skipFlexVar + stEnd.skipFlexVar
                                                , skipNoInfo = tAcc.skipNoInfo + stEnd.skipNoInfo
                                                , byModule =
                                                    if stEnd.wrote > 0 then
                                                        Dict.update (moduleOf key)
                                                            (\c -> Just (stEnd.wrote + Maybe.withDefault 0 c))
                                                            tAcc.byModule

                                                    else
                                                        tAcc.byModule
                                                }
                                        in
                                        if stEnd.wrote > 0 then
                                            ( idx + 1, ( Registry.updateRegistryType idx rewritten reg, tAcc1 ) )

                                        else
                                            ( idx + 1, ( reg, tAcc1 ) )

                                    else
                                        ( idx + 1, ( reg, tAcc ) )

                                Nothing ->
                                    ( idx + 1, ( reg, tAcc ) )
                        )
                        ( 0, ( s.registry, { wrote = 0, skipTop = 0, skipFlexVar = 0, skipNoInfo = 0, byModule = Dict.empty } ) )
                        s.registry.reverseMapping
                    )

            bumpN key n acc =
                List.foldl (\_ a -> Engine.bumpArgFlowCensus key a) acc (List.repeat n ())

            s1 =
                { s | registry = registry1 }
                    |> bumpN "varctor|wrote" totals.wrote
                    |> bumpN "varctor|skipTop" totals.skipTop
                    |> bumpN "varctor|skipFlexVar" totals.skipFlexVar
                    |> bumpN "varctor|skipNoInfo" totals.skipNoInfo
        in
        Dict.foldl (\m n acc -> bumpN ("varctor|mod|" ++ m) n acc) s1 totals.byModule


{-| Returns the state with set variables in registry types filled from the
result types of the closures in the translated nodes. Does nothing with LSS
off.

A closure's result set is held in one place: the type of its body, inside the
node that contains the closure. Registry rows hold the types of specs, not of
values inside their bodies, so this pass reads the closures, through
`lambdaHomesOf`.

In each row, an arrow whose annotation is an `LSet` opens a context when every
member of the set is a closure member recorded with as many parameters as the
arrow takes arguments; the context is the merged cells of those closures'
bodies. Below that arrow, along its result and through lists, tuples, records
and custom types, an `LVar` is replaced by the union in the matching cell when
that cell has no ⊤ and no unresolved set. Arguments get no context from above,
and any `LSet` met below opens its own context or, if its members fail the
test, none.

-}
settleVarLambda : S -> S
settleVarLambda s =
    if not s.env.lss.enabled then
        s

    else
        let
            homes =
                lambdaHomesOf s.nodes

            -- Nothing unless every member has a closure entry of arity `nargs`.
            openCtx ms nargs =
                List.foldl
                    (\m acc ->
                        case acc of
                            Nothing ->
                                Nothing

                            Just cm ->
                                case Dict.get m homes of
                                    Just home ->
                                        if home.arity == Just nargs then
                                            Just (varMapMerge cm home.cells)

                                        else
                                            Nothing

                                    Nothing ->
                                        Nothing
                    )
                    (Just Dict.empty)
                    ms

            rewrite t ctx st =
                case t of
                    Mono.MFunction _ anno args result ->
                        let
                            ( anno1, st1 ) =
                                case ( anno, ctx ) of
                                    ( Mono.LVar _, Just ( cm, rp ) ) ->
                                        case Dict.get rp cm of
                                            Just cell ->
                                                if cell.top || cell.var then
                                                    ( anno, { st | blocked = st.blocked + 1 } )

                                                else
                                                    case cell.sets of
                                                        Just ss ->
                                                            ( Mono.LSet ss, { st | wrote = st.wrote + 1 } )

                                                        Nothing ->
                                                            ( anno, st )

                                            Nothing ->
                                                ( anno, st )

                                    _ ->
                                        ( anno, st )

                            -- Opened by the annotation as it was, so a set just written here does not reopen.
                            ctxR =
                                case anno of
                                    Mono.LSet ms ->
                                        Maybe.map (\cm -> ( cm, "/r" )) (openCtx ms (List.length args))

                                    _ ->
                                        Maybe.map (\( cm, rp ) -> ( cm, rp ++ "/r" )) ctx

                            ( result1, st2 ) =
                                rewrite result ctxR st1

                            ( args1, st3 ) =
                                List.foldr
                                    (\a ( accL, accSt ) ->
                                        let
                                            ( a1, accSt1 ) =
                                                rewrite a Nothing accSt
                                        in
                                        ( a1 :: accL, accSt1 )
                                    )
                                    ( [], st2 )
                                    args
                        in
                        ( Mono.mFunction anno1 args1 result1, st3 )

                    Mono.MList _ inner ->
                        let
                            ( inner1, st1 ) =
                                rewrite inner (Maybe.map (\( cm, rp ) -> ( cm, rp ++ "/l" )) ctx) st
                        in
                        ( Mono.mList inner1, st1 )

                    Mono.MTuple _ elems ->
                        let
                            ( elems1, st1 ) =
                                List.foldr
                                    (\( i, e ) ( accL, accSt ) ->
                                        let
                                            ( e1, accSt1 ) =
                                                rewrite e
                                                    (Maybe.map (\( cm, rp ) -> ( cm, rp ++ "/t" ++ String.fromInt i )) ctx)
                                                    accSt
                                        in
                                        ( e1 :: accL, accSt1 )
                                    )
                                    ( [], st )
                                    (List.indexedMap Tuple.pair elems)
                        in
                        ( Mono.mTuple elems1, st1 )

                    Mono.MRecord _ fields ->
                        let
                            ( fields1, st1 ) =
                                Dict.foldl
                                    (\fn ft ( accD, accSt ) ->
                                        let
                                            ( ft1, accSt1 ) =
                                                rewrite ft
                                                    (Maybe.map (\( cm, rp ) -> ( cm, rp ++ "/f:" ++ fn )) ctx)
                                                    accSt
                                        in
                                        ( Dict.insert fn ft1 accD, accSt1 )
                                    )
                                    ( Dict.empty, st )
                                    fields
                        in
                        ( Mono.mRecord fields1, st1 )

                    Mono.MCustom _ vlHome vlName args ->
                        let
                            ( args1, st1 ) =
                                List.foldr
                                    (\( i, a ) ( accL, accSt ) ->
                                        let
                                            ( a1, accSt1 ) =
                                                rewrite a
                                                    (Maybe.map (\( cm, rp ) -> ( cm, rp ++ "/c" ++ String.fromInt i )) ctx)
                                                    accSt
                                        in
                                        ( a1 :: accL, accSt1 )
                                    )
                                    ( [], st )
                                    (List.indexedMap Tuple.pair args)
                        in
                        ( Mono.mCustom vlHome vlName args1, st1 )

                    _ ->
                        ( t, st )

            ( registry1, totals ) =
                Tuple.second
                    (Array.foldl
                        (\entry ( idx, ( reg, tAcc ) ) ->
                            case entry of
                                Just ( _, monoType ) ->
                                    let
                                        ( rewritten, stEnd ) =
                                            rewrite monoType Nothing { wrote = 0, blocked = 0 }

                                        tAcc1 =
                                            { wrote = tAcc.wrote + stEnd.wrote
                                            , blocked = tAcc.blocked + stEnd.blocked
                                            }
                                    in
                                    if stEnd.wrote > 0 then
                                        ( idx + 1, ( Registry.updateRegistryType idx rewritten reg, tAcc1 ) )

                                    else
                                        ( idx + 1, ( reg, tAcc1 ) )

                                Nothing ->
                                    ( idx + 1, ( reg, tAcc ) )
                        )
                        ( 0, ( s.registry, { wrote = 0, blocked = 0 } ) )
                        s.registry.reverseMapping
                    )

            bumpN key n acc =
                List.foldl (\_ a -> Engine.bumpArgFlowCensus key a) acc (List.repeat n ())
        in
        { s | registry = registry1 }
            |> bumpN "varlam|wrote" totals.wrote
            |> bumpN "varlam|blocked" totals.blocked
            |> bumpN "varlam|mids" (Dict.size homes)


{-| Returns, by member id, every closure with an LSS member in the translated
nodes, except closures inside a closure's captures: its parameter count and
the cells of its body's type, keyed by position path relative to the closure's
own arrow, so that `/r` is the body's type.

Closures with the same member have their cells merged. Where they disagree on
the parameter count the count is `Nothing`, since a path would then name
different parts of their types.

-}
lambdaHomesOf : Array (Maybe Mono.MonoNode) -> Dict.Dict Int { arity : Maybe Int, cells : Dict.Dict String VarCell }
lambdaHomesOf nodes =
    Array.foldl
        (\entry acc ->
            case entry of
                Just (Mono.MonoDefine expr _) ->
                    lambdaHomesExpr expr acc

                Just (Mono.MonoTailFunc _ expr _) ->
                    lambdaHomesExpr expr acc

                Just (Mono.MonoPortIncoming expr _) ->
                    lambdaHomesExpr expr acc

                Just (Mono.MonoPortOutgoing expr _) ->
                    lambdaHomesExpr expr acc

                _ ->
                    acc
        )
        Dict.empty
        nodes


{-| Returns `acc` with every closure in `e` recorded by `recordLambdaHome`,
closures nested in other closures included, though not closures in a closure's
captures.
-}
lambdaHomesExpr : Mono.MonoExpr -> Dict.Dict Int { arity : Maybe Int, cells : Dict.Dict String VarCell } -> Dict.Dict Int { arity : Maybe Int, cells : Dict.Dict String VarCell }
lambdaHomesExpr e acc =
    case e of
        Mono.MonoClosure info body _ ->
            lambdaHomesExpr body (recordLambdaHome info body acc)

        Mono.MonoList _ items _ ->
            List.foldl lambdaHomesExpr acc items

        Mono.MonoCall _ f args _ _ ->
            List.foldl lambdaHomesExpr (lambdaHomesExpr f acc) args

        Mono.MonoTailCall _ entries _ ->
            List.foldl (\( _, x ) aa -> lambdaHomesExpr x aa) acc entries

        Mono.MonoIf branches final _ ->
            lambdaHomesExpr final
                (List.foldl (\( c, th ) aa -> lambdaHomesExpr th (lambdaHomesExpr c aa)) acc branches)

        Mono.MonoLet def body _ ->
            lambdaHomesExpr body
                (case def of
                    Mono.MonoDef _ bound ->
                        lambdaHomesExpr bound acc

                    Mono.MonoTailDef _ _ bound ->
                        lambdaHomesExpr bound acc
                )

        Mono.MonoDestruct _ inner _ ->
            lambdaHomesExpr inner acc

        Mono.MonoCase _ _ decider branches _ ->
            List.foldl (\( _, x ) aa -> lambdaHomesExpr x aa)
                (List.foldl lambdaHomesExpr acc (lambdaHomeDeciderExprs decider []))
                branches

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, x ) aa -> lambdaHomesExpr x aa) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            lambdaHomesExpr inner acc

        Mono.MonoRecordUpdate inner updates _ ->
            List.foldl (\( _, x ) aa -> lambdaHomesExpr x aa) (lambdaHomesExpr inner acc) updates

        Mono.MonoTupleCreate _ items _ ->
            List.foldl lambdaHomesExpr acc items

        _ ->
            acc


{-| Returns the expressions at the `Inline` leaves of a decision tree, consed
onto `acc`.
-}
lambdaHomeDeciderExprs : Mono.Decider Mono.MonoChoice -> List Mono.MonoExpr -> List Mono.MonoExpr
lambdaHomeDeciderExprs d acc =
    case d of
        Mono.Leaf (Mono.Inline e) ->
            e :: acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            lambdaHomeDeciderExprs failure (lambdaHomeDeciderExprs success acc)

        Mono.FanOut _ tests fallback ->
            lambdaHomeDeciderExprs fallback
                (List.foldl (\( _, dd ) aa -> lambdaHomeDeciderExprs dd aa) acc tests)


{-| Returns `acc` with the closure described by `info` and `body` recorded under
its LSS member, as `lambdaHomesOf` describes. A closure without a member leaves
`acc` unchanged.
-}
recordLambdaHome : Mono.ClosureInfo -> Mono.MonoExpr -> Dict.Dict Int { arity : Maybe Int, cells : Dict.Dict String VarCell } -> Dict.Dict Int { arity : Maybe Int, cells : Dict.Dict String VarCell }
recordLambdaHome info body acc =
    case info.lssMember of
        Just mid ->
            let
                bodyType =
                    Mono.typeOf body

                thisArity =
                    List.length info.params

                cells =
                    varCellWalk "/r" bodyType Dict.empty
            in
            Dict.update mid
                (\v ->
                    Just
                        (case v of
                            Just cur ->
                                { arity =
                                    if cur.arity == Just thisArity then
                                        cur.arity

                                    else
                                        Nothing
                                , cells = varMapMerge cur.cells cells
                                }

                            Nothing ->
                                { arity = Just thisArity, cells = cells }
                        )
                )
                acc

        Nothing ->
            acc


{-| What the arrows at one position path hold, gathered over several types:
whether any carries ⊤, whether any carries an `LVar` or `LPartial` (`var`), and
the union of the members of every `LSet` there, `Nothing` when there is none.
-}
type alias VarCell =
    { top : Bool, var : Bool, sets : Maybe (List Int) }


{-| The cell of a position at which nothing has been seen.
-}
varCellEmpty : VarCell
varCellEmpty =
    { top = False, var = False, sets = Nothing }


{-| Returns the cell holding what both cells hold.
-}
varCellMerge : VarCell -> VarCell -> VarCell
varCellMerge ca cb =
    { top = ca.top || cb.top
    , var = ca.var || cb.var
    , sets =
        case ( ca.sets, cb.sets ) of
            ( Just xs, Just ys ) ->
                Just (Mono.unionSortedInts xs ys)

            ( Just xs, Nothing ) ->
                Just xs

            ( Nothing, sb ) ->
                sb
    }


{-| Returns the two cell maps combined, with the cells at a path both have
merged.
-}
varMapMerge : Dict.Dict String VarCell -> Dict.Dict String VarCell -> Dict.Dict String VarCell
varMapMerge a b =
    Dict.foldl
        (\k cell d -> Dict.update k (\v -> Just (varCellMerge (Maybe.withDefault varCellEmpty v) cell)) d)
        a
        b


{-| Returns `acc` with the annotation of every arrow in `t` added to the cell of
its position path, `t` itself being at `path`.
-}
varCellWalk : String -> Mono.MonoType -> Dict.Dict String VarCell -> Dict.Dict String VarCell
varCellWalk path t acc =
    case t of
        Mono.MFunction _ anno args result ->
            let
                acc1 =
                    Dict.update path
                        (\v ->
                            let
                                c =
                                    Maybe.withDefault varCellEmpty v
                            in
                            Just
                                (case anno of
                                    Mono.LTop _ ->
                                        { c | top = True }

                                    Mono.LVar _ ->
                                        { c | var = True }

                                    -- A lower bound counts as unresolved.
                                    Mono.LPartial _ ->
                                        { c | var = True }

                                    Mono.LSet ms ->
                                        { c | sets = Just (Mono.unionSortedInts ms (Maybe.withDefault [] c.sets)) }
                                )
                        )
                        acc

                accR =
                    varCellWalk (path ++ "/r") result acc1
            in
            List.foldl (\( i, a ) aa -> varCellWalk (path ++ "/a" ++ String.fromInt i) a aa)
                accR
                (List.indexedMap Tuple.pair args)

        Mono.MList _ inner ->
            varCellWalk (path ++ "/l") inner acc

        Mono.MTuple _ elems ->
            List.foldl (\( i, e ) aa -> varCellWalk (path ++ "/t" ++ String.fromInt i) e aa)
                acc
                (List.indexedMap Tuple.pair elems)

        Mono.MRecord _ fields ->
            Dict.foldl (\fn ft aa -> varCellWalk (path ++ "/f:" ++ fn) ft aa) acc fields

        Mono.MCustom _ _ _ args ->
            List.foldl (\( i, a ) aa -> varCellWalk (path ++ "/c" ++ String.fromInt i) a aa)
                acc
                (List.indexedMap Tuple.pair args)

        _ ->
            acc


{-| Returns the state with set variables below sets of partially applicable
members filled with the members' next partial applications. Does nothing with
LSS off.

A member is _pap-able_ when it is a global (`g|X`), a constructor (`c|X`) or a
partial application (`p|X|k`). Applying it to `j` more arguments, short of X's
declared arity, can only give the partial application `p|X|k+j`, with `k` taken
as 0 for a global or constructor. So where an arrow's set holds only pap-able
members and its result arrow has an `LVar`, that result is given the set of
those successors, `j` being the number of arguments the arrow takes. It is all
or nothing: if any member is not pap-able, or `k + j` reaches
`LssInfer.declaredArityOf X`, the position is left alone, because the arrow past
the last parameter belongs to whatever the body returns.

The successor ids come from `Engine.papMemberIdFor`, so they are the ids every
other part of the engine gives those partial applications. Each row is walked
from the top of its result spine down, so a chain of any depth is filled in one
pass. With `lss.report` on, a second pass checks that nothing is left to do;
its registry and member table are discarded; its census counts, including the
verify count, are kept.

-}
settleVarSuccessors : S -> S
settleVarSuccessors s0 =
    if not s0.env.lss.enabled then
        s0

    else
        let
            ( s1, _ ) =
                varSuccPass s0
        in
        if s0.env.lss.report then
            let
                ( s2, changed2 ) =
                    varSuccPass s1
            in
            Engine.bumpArgFlowCensus
                (if changed2 then
                    "varsucc|verifyCHANGED"

                 else
                    "varsucc|verifyClean"
                )
                (Engine.bumpArgFlowCensus "varsucc|rounds" { s1 | lssStats = s2.lssStats })

        else
            Engine.bumpArgFlowCensus "varsucc|rounds" s1


{-| Returns the state after one successor pass over every registry row, as
`settleVarSuccessors` describes, and whether any row changed.
-}
varSuccPass : S -> ( S, Bool )
varSuccPass s =
    let
        midKeys =
            Dict.foldl (\k mid acc -> Dict.insert mid k acc) Dict.empty s.lssMemberTable.byKey

        compGlobals =
            HashMap.foldl
                (\vsG _ acc -> Dict.insert (TOpt.toComparableGlobal vsG) vsG acc)
                Dict.empty
                s.env.toptNodes

        -- Minted successors join the key map at once, so the walk can go on below them.
        succSetFor j ms sIn =
            List.foldl
                (\m ( maybeAcc, ( sAcc, keysAcc ) ) ->
                    case maybeAcc of
                        Nothing ->
                            ( Nothing, ( sAcc, keysAcc ) )

                        Just acc ->
                            case Dict.get m keysAcc of
                                Nothing ->
                                    ( Nothing, ( Engine.bumpArgFlowCensus "varsucc|skipNoSucc" sAcc, keysAcc ) )

                                Just mkey ->
                                    let
                                        papable =
                                            case String.split "|" mkey of
                                                "p" :: gstr :: dstr :: _ ->
                                                    Maybe.map2 Tuple.pair (Dict.get gstr compGlobals) (String.toInt dstr)

                                                "g" :: gstr :: _ ->
                                                    Maybe.map (\vsG -> ( vsG, 0 )) (Dict.get gstr compGlobals)

                                                "c" :: gstr :: _ ->
                                                    Maybe.map (\vsG -> ( vsG, 0 )) (Dict.get gstr compGlobals)

                                                _ ->
                                                    Nothing
                                    in
                                    case papable of
                                        Nothing ->
                                            ( Nothing, ( Engine.bumpArgFlowCensus "varsucc|skipNoSucc" sAcc, keysAcc ) )

                                        Just ( vsG, d ) ->
                                            if d + j < LssInfer.declaredArityOf vsG 8 sAcc then
                                                let
                                                    succKey =
                                                        LssInfer.papMemberKey vsG (d + j)
                                                in
                                                case Engine.papMemberIdFor vsG (d + j) sAcc of
                                                    ( mid, sAcc1 ) ->
                                                        ( Just (Mono.unionSortedInts [ mid ] acc)
                                                        , ( sAcc1, Dict.insert mid succKey keysAcc )
                                                        )

                                            else
                                                ( Nothing, ( Engine.bumpArgFlowCensus "varsucc|skipBeyond" sAcc, keysAcc ) )
                )
                ( Just [], sIn )
                ms

        succType t sIn =
            case t of
                Mono.MFunction _ anno args result ->
                    let
                        ( resultW, sW, chW ) =
                            case ( anno, result ) of
                                ( Mono.LSet ms, Mono.MFunction _ (Mono.LVar _) rArgs rRes ) ->
                                    case succSetFor (List.length args) ms sIn of
                                        ( Just succ, ( s1, k1 ) ) ->
                                            ( Mono.mFunction (Mono.LSet succ) rArgs rRes
                                            , ( Engine.bumpArgFlowCensus
                                                    (if List.length ms == 1 then
                                                        "varsucc|wrote1"

                                                     else
                                                        "varsucc|wroteN"
                                                    )
                                                    s1
                                              , k1
                                              )
                                            , True
                                            )

                                        ( Nothing, sSkip ) ->
                                            ( result, sSkip, False )

                                _ ->
                                    ( result, sIn, False )

                        ( result1, sR, chR ) =
                            succType resultW sW

                        ( args1, sA, chA ) =
                            List.foldr
                                (\a ( accL, accS, accCh ) ->
                                    let
                                        ( a1, accS1, ch1 ) =
                                            succType a accS
                                    in
                                    ( a1 :: accL, accS1, accCh || ch1 )
                                )
                                ( [], sR, False )
                                args
                    in
                    -- An unchanged subtree is returned as it was rather than rebuilt.
                    if chW || chR || chA then
                        ( Mono.mFunction anno args1 result1, sA, True )

                    else
                        ( t, sA, False )

                Mono.MList _ inner ->
                    let
                        ( inner1, s1, ch ) =
                            succType inner sIn
                    in
                    if ch then
                        ( Mono.mList inner1, s1, True )

                    else
                        ( t, s1, False )

                Mono.MTuple _ elems ->
                    let
                        ( elems1, s1, ch ) =
                            List.foldr
                                (\e ( accL, accS, accCh ) ->
                                    let
                                        ( e1, accS1, ch1 ) =
                                            succType e accS
                                    in
                                    ( e1 :: accL, accS1, accCh || ch1 )
                                )
                                ( [], sIn, False )
                                elems
                    in
                    if ch then
                        ( Mono.mTuple elems1, s1, True )

                    else
                        ( t, s1, False )

                Mono.MRecord _ fields ->
                    let
                        ( fields1, s1, ch ) =
                            Dict.foldl
                                (\fname ft ( accD, accS, accCh ) ->
                                    let
                                        ( ft1, accS1, ch1 ) =
                                            succType ft accS
                                    in
                                    if ch1 then
                                        ( Dict.insert fname ft1 accD, accS1, True )

                                    else
                                        ( accD, accS1, accCh )
                                )
                                ( fields, sIn, False )
                                fields
                    in
                    if ch then
                        ( Mono.mRecord fields1, s1, True )

                    else
                        ( t, s1, False )

                Mono.MCustom _ vsHome vsName args ->
                    let
                        ( args1, s1, ch ) =
                            List.foldr
                                (\a ( accL, accS, accCh ) ->
                                    let
                                        ( a1, accS1, ch1 ) =
                                            succType a accS
                                    in
                                    ( a1 :: accL, accS1, accCh || ch1 )
                                )
                                ( [], sIn, False )
                                args
                    in
                    if ch then
                        ( Mono.mCustom vsHome vsName args1, s1, True )

                    else
                        ( t, s1, False )

                _ ->
                    ( t, sIn, False )

        ( ( sEnd, _ ), changed ) =
            Tuple.second
                (Array.foldl
                    (\entry ( idx, ( stAcc, chAcc ) ) ->
                        case entry of
                            Just ( _, monoType ) ->
                                let
                                    ( rewritten, ( sAcc1, kAcc1 ), ch ) =
                                        succType monoType stAcc
                                in
                                if ch then
                                    ( idx + 1
                                    , ( ( { sAcc1 | registry = Registry.updateRegistryType idx rewritten sAcc1.registry }
                                        , kAcc1
                                        )
                                      , True
                                      )
                                    )

                                else
                                    ( idx + 1, ( ( sAcc1, kAcc1 ), chAcc ) )

                            Nothing ->
                                ( idx + 1, ( stAcc, chAcc ) )
                    )
                    ( 0, ( ( s, midKeys ), False ) )
                    s.registry.reverseMapping
                )
    in
    ( sEnd, changed )


{-| Returns the LSS census as text, from the final state and the pruned graph.

Among other things the lines count the members, the lambda sets read back by
size, the arrows in the pruned registry's types by the form of their annotation
(`coverage:`), and every set read-back by its outcome (`ledger:`, and
`ledger-settled:` for the same read-backs replayed when each item had
finished). Several lines check their own totals and print `RECONCILES=yes` or
`NO`. The lines from `stampwalk:` to the `pos|` rows appear only with
`lss.arrowCensus`, and the `Q-infer:` and `Q-shadow:` lines only with
`lss.qCensus`.

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
            HashMap.size sFinal.lssSignatures

        trivialCount =
            HashMap.foldl
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

        -- Every set read-back falls in one of five buckets, which must sum to `setsZonked`.
        censusAt key =
            Maybe.withDefault 0 (Dict.get key stats.sigStats.argFlowCensus)

        ledgerK1 =
            Maybe.withDefault 0 (Dict.get 1 stats.sizeHist)

        ledgerKN =
            Dict.foldl
                (\size count acc ->
                    if size >= 2 then
                        acc + count

                    else
                        acc
                )
                0
                stats.sizeHist

        ledgerTop =
            censusAt "zc|all|poison" + censusAt "zc|all|edgeTop"

        -- The read-backs that gave an `LVar`.
        ledgerUnknown =
            censusAt "zc|all|flex" + censusAt "zc|all|edgeEmpty"

        ledgerSum =
            ledgerK1 + ledgerKN + stats.widenedBySize + ledgerTop + ledgerUnknown

        multiSetArrowHist =
            let
                h =
                    Dict.foldl (\_ ms acc -> Dict.insert (List.length ms) (1 + Maybe.withDefault 0 (Dict.get (List.length ms) acc)) acc) Dict.empty stats.sigStats.multiSetsByArrow
            in
            if Dict.isEmpty h then
                "(none)"

            else
                String.join " " (Dict.foldr (\k v acc -> (String.fromInt k ++ "->" ++ String.fromInt v) :: acc) [] h)

        -- The same read-backs replayed when each item had finished (`Store.rezonkSettled`).
        settled =
            stats.sigStats.settled

        settledK1 =
            Maybe.withDefault 0 (Dict.get 1 settled.hist)

        settledKN =
            Dict.foldl
                (\size count acc ->
                    if size >= 2 then
                        acc + count

                    else
                        acc
                )
                0
                settled.hist

        settledSum =
            settledK1 + settledKN + settled.widenedBySize + settled.causeTop + settled.causeVar

        q =
            stats.sigStats.qShadow

        qi =
            stats.sigStats.qInfer

        qiDiverge =
            qi.divergeSuper + qi.divergeSub + qi.divergeTop + qi.divergeOther

        qInferLine =
            "Q-infer: constraints="
                ++ String.fromInt (qi.members + qi.tops + qi.edges)
                ++ " (members="
                ++ String.fromInt qi.members
                ++ " tops="
                ++ String.fromInt qi.tops
                ++ " edges="
                ++ String.fromInt qi.edges
                ++ ") units="
                ++ String.fromInt qi.items
                ++ " classes="
                ++ String.fromInt qi.classes
                ++ " agree="
                ++ String.fromInt qi.agree
                ++ " diverge="
                ++ String.fromInt qiDiverge
                ++ "(super="
                ++ String.fromInt qi.divergeSuper
                ++ " sub="
                ++ String.fromInt qi.divergeSub
                ++ "[merged="
                ++ String.fromInt qi.subMerged
                ++ " unseen="
                ++ String.fromInt qi.subUnseen
                ++ "] top="
                ++ String.fromInt qi.divergeTop
                ++ " other="
                ++ String.fromInt qi.divergeOther
                ++ ") | partition reaching="
                ++ String.fromInt qi.reaching
                ++ " internal="
                ++ String.fromInt qi.internal
                ++ "(agree="
                ++ String.fromInt qi.internAgree
                ++ " diverge="
                ++ String.fromInt qi.internDiverge
                ++ ") REPRODUCES="
                ++ (if qiDiverge == 0 then
                        "yes"

                    else
                        "NO"
                   )

        qDiverge =
            q.divergeSuper + q.divergeSub + q.divergeTop + q.divergeOther

        qDefined =
            q.classes - q.unresolved

        qLine =
            "Q-shadow: constraints="
                ++ String.fromInt (q.members + q.tops + q.edges)
                ++ " (members="
                ++ String.fromInt q.members
                ++ " tops="
                ++ String.fromInt q.tops
                ++ " edges="
                ++ String.fromInt q.edges
                ++ ") items="
                ++ String.fromInt q.items
                ++ " classes="
                ++ String.fromInt q.classes
                ++ " defined="
                ++ String.fromInt qDefined
                ++ " agree="
                ++ String.fromInt q.agree
                ++ " diverge="
                ++ String.fromInt qDiverge
                ++ "(super="
                ++ String.fromInt q.divergeSuper
                ++ " sub="
                ++ String.fromInt q.divergeSub
                ++ "[merged="
                ++ String.fromInt q.subMerged
                ++ " unseen="
                ++ String.fromInt q.subUnseen
                ++ "]"
                ++ " top="
                ++ String.fromInt q.divergeTop
                ++ " other="
                ++ String.fromInt q.divergeOther
                ++ ") unresolved="
                ++ String.fromInt q.unresolved
                ++ " edgeOnly="
                ++ String.fromInt q.edgeClasses
                ++ " scratchDropped="
                ++ String.fromInt q.scratchDropped
                ++ " | partition sigRoots="
                ++ String.fromInt q.sigRoots
                ++ " reaching="
                ++ String.fromInt q.reaching
                ++ " internal="
                ++ String.fromInt q.internal
                ++ "(agree="
                ++ String.fromInt q.internAgree
                ++ " diverge="
                ++ String.fromInt q.internDiverge
                ++ ")"
                ++ " REPRODUCES="
                ++ (if qDiverge == 0 then
                        "yes"

                    else
                        "NO"
                   )

        qSampleLines =
            String.join "\n" q.divergeSamples

        settledLine =
            "ledger-settled: k1="
                ++ String.fromInt settledK1
                ++ " kN="
                ++ String.fromInt settledKN
                ++ " overcap="
                ++ String.fromInt settled.widenedBySize
                ++ " top="
                ++ String.fromInt settled.causeTop
                ++ " var="
                ++ String.fromInt settled.causeVar
                ++ " total="
                ++ String.fromInt settled.zonked
                ++ " items="
                ++ String.fromInt settled.items
                ++ " RECONCILES="
                ++ (if settledSum == settled.zonked then
                        "yes"

                    else
                        "NO(" ++ String.fromInt settledSum ++ ")"
                   )
                ++ " MATCHES="
                ++ (if settled.zonked == stats.setsZonked then
                        "yes"

                    else
                        -- Read-backs made in a scratch store cannot be replayed; `scratchCalls` counts them.
                        "NO(inflight="
                            ++ String.fromInt stats.setsZonked
                            ++ " short="
                            ++ String.fromInt (stats.setsZonked - settled.zonked)
                            ++ " scratchCalls="
                            ++ String.fromInt settled.scratchDropped
                            ++ ")"
                   )
                ++ " dVar="
                ++ String.fromInt (settled.causeVar - ledgerUnknown)
                ++ " dK1="
                ++ String.fromInt (settledK1 - ledgerK1)
                ++ " dKN="
                ++ String.fromInt (settledKN - ledgerKN)

        -- Settled `LVar` arrows, by whether the same arrow read back a set anywhere in the run.
        settledKnownElsewhere =
            Dict.foldl
                (\akey n ( known, unknown ) ->
                    if Dict.member akey settled.setArrows then
                        ( known + n, unknown )

                    else
                        ( known, unknown + n )
                )
                ( 0, 0 )
                settled.varArrows

        settledArrowLine =
            let
                ( known, unknown ) =
                    settledKnownElsewhere

                knownArrows =
                    Dict.foldl
                        (\akey _ n ->
                            if Dict.member akey settled.setArrows then
                                n + 1

                            else
                                n
                        )
                        0
                        settled.varArrows
            in
            "settled-var-arrows: varArrows="
                ++ String.fromInt (Dict.size settled.varArrows)
                ++ " setArrows="
                ++ String.fromInt (Dict.size settled.setArrows)
                ++ " attributed="
                ++ String.fromInt (known + unknown)
                ++ " ofVar="
                ++ String.fromInt settled.causeVar
                ++ " knownElsewhere="
                ++ String.fromInt known
                ++ "/"
                ++ String.fromInt knownArrows
                ++ "arr unknownEverywhere="
                ++ String.fromInt unknown
                ++ "/"
                ++ String.fromInt (Dict.size settled.varArrows - knownArrows)
                ++ "arr"

        -- One count per arrow of each type in the pruned registry, however often it was read.
        coverage =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( _, monoType ) ->
                            Mono.annoCoverage monoType acc

                        Nothing ->
                            acc
                )
                Mono.emptyAnnoCoverage
                g.registry.reverseMapping

        coverageLine =
            let
                concrete =
                    coverage.k1 + coverage.kN

                -- An `LPartial` is counted as a position but not as covered.
                positions =
                    concrete + coverage.var + coverage.top + coverage.part + coverage.row
            in
            "coverage: positions="
                ++ String.fromInt positions
                ++ " k1="
                ++ String.fromInt coverage.k1
                ++ " kN="
                ++ String.fromInt coverage.kN
                ++ " var="
                ++ String.fromInt coverage.var
                ++ " top="
                ++ String.fromInt coverage.top
                ++ " part="
                ++ String.fromInt coverage.part
                ++ " row="
                ++ String.fromInt coverage.row
                ++ " coveredBp="
                ++ String.fromInt
                    (if positions == 0 then
                        0

                     else
                        (10000 * concrete) // positions
                    )

        -- One `pos|` row per arrow: global, path, annotation form, registry index.
        memberKeyOf =
            Dict.foldl (\k mid acc -> Dict.insert mid k acc) Dict.empty sFinal.lssMemberTable.byKey

        posWalk path monoType acc =
            case monoType of
                Mono.MFunction _ anno args result ->
                    let
                        acc1 =
                            case anno of
                                Mono.LSet [ m ] ->
                                    ( path
                                      -- `|` in a member key becomes `;`, keeping five fields per row.
                                    , "k1:"
                                        ++ (case Dict.get m memberKeyOf of
                                                Just mk ->
                                                    String.replace "|" ";" mk

                                                Nothing ->
                                                    "m" ++ String.fromInt m
                                           )
                                    )
                                        :: acc

                                Mono.LSet _ ->
                                    ( path, "kN" ) :: acc

                                Mono.LPartial ms ->
                                    ( path, "part@" ++ String.fromInt (List.length ms) ) :: acc

                                Mono.LVar vn ->
                                    ( path, "var@" ++ String.fromInt vn ) :: acc

                                Mono.LTop tpK ->
                                    ( path, "top@" ++ Mono.topKindLabel tpK ) :: acc

                        accR =
                            posWalk (path ++ "/r") result acc1
                    in
                    List.foldl
                        (\( i, a ) accA ->
                            posWalk (path ++ "/a" ++ String.fromInt i) a accA
                        )
                        accR
                        (List.indexedMap Tuple.pair args)

                Mono.MList _ inner ->
                    posWalk (path ++ "/l") inner acc

                Mono.MTuple _ elems ->
                    List.foldl
                        (\( i, e ) accE ->
                            posWalk (path ++ "/t" ++ String.fromInt i) e accE
                        )
                        acc
                        (List.indexedMap Tuple.pair elems)

                Mono.MRecord _ fields ->
                    Dict.foldl (\fname t a -> posWalk (path ++ "/f:" ++ fname) t a) acc fields

                Mono.MCustom _ _ _ args ->
                    List.foldl
                        (\( i, a ) accA ->
                            posWalk (path ++ "/c" ++ String.fromInt i) a accA
                        )
                        acc
                        (List.indexedMap Tuple.pair args)

                _ ->
                    acc

        posRows =
            Tuple.second
                (Array.foldl
                    (\entry ( idx, acc ) ->
                        case entry of
                            Just ( key, monoType ) ->
                                let
                                    gname =
                                        case key of
                                            Mono.Global _ n ->
                                                n

                                            _ ->
                                                "?"

                                    -- An `LVar` number is only meaningful within the type it was read from.
                                    qualify kind =
                                        if String.startsWith "var@" kind then
                                            "var@" ++ String.fromInt idx ++ "." ++ String.dropLeft 4 kind

                                        else
                                            kind
                                in
                                ( idx + 1
                                , List.map (\( pth, kind ) -> "pos|" ++ gname ++ "|" ++ pth ++ "|" ++ qualify kind ++ "|" ++ String.fromInt idx)
                                    (posWalk "" monoType [])
                                    ++ acc
                                )

                            Nothing ->
                                ( idx + 1, acc )
                    )
                    ( 0, [] )
                    g.registry.reverseMapping
                )

        posLine =
            String.join "\n" (List.sort posRows)

        varfixComparableGlobals =
            HashMap.foldl
                (\vfG _ acc -> Dict.insert (TOpt.toComparableGlobal vfG) vfG acc)
                Dict.empty
                sFinal.env.toptNodes

        -- The global and arguments supplied, for a `p|`, `g|` or `c|` member.
        varfixPapable mid =
            case Dict.get mid memberKeyOf of
                Nothing ->
                    Nothing

                Just mkey ->
                    case String.split "|" mkey of
                        "p" :: gstr :: dstr :: _ ->
                            Maybe.map2 Tuple.pair
                                (Dict.get gstr varfixComparableGlobals)
                                (String.toInt dstr)

                        "g" :: gstr :: _ ->
                            Maybe.map (\vfG -> ( vfG, 0 )) (Dict.get gstr varfixComparableGlobals)

                        "c" :: gstr :: _ ->
                            Maybe.map (\vfG -> ( vfG, 0 )) (Dict.get gstr varfixComparableGlobals)

                        _ ->
                            Nothing

        -- Set arrows whose result is an `LVar`: 0 successor writable, 1 past arity, 2 no successor.
        varfixWalk rowG t acc =
            case t of
                Mono.MFunction _ anno args result ->
                    let
                        accCand =
                            case ( anno, result ) of
                                ( Mono.LSet ms, Mono.MFunction _ (Mono.LVar _) _ _ ) ->
                                    let
                                        j =
                                            List.length args

                                        verdict m =
                                            case varfixPapable m of
                                                Nothing ->
                                                    2

                                                Just ( vfG, d ) ->
                                                    if d + j < LssInfer.declaredArityOf vfG 8 sFinal then
                                                        0

                                                    else
                                                        1

                                        worst =
                                            List.foldl (\m w -> max w (verdict m)) 0 ms
                                    in
                                    if worst == 0 then
                                        if List.length ms == 1 then
                                            { acc
                                                | would1 = acc.would1 + 1
                                                , byG = Dict.update rowG (\c -> Just (1 + Maybe.withDefault 0 c)) acc.byG
                                            }

                                        else
                                            { acc
                                                | wouldN = acc.wouldN + 1
                                                , byG = Dict.update rowG (\c -> Just (1 + Maybe.withDefault 0 c)) acc.byG
                                            }

                                    else if worst == 1 then
                                        { acc | beyond = acc.beyond + 1 }

                                    else
                                        { acc | noSucc = acc.noSucc + 1 }

                                _ ->
                                    acc
                    in
                    varfixWalk rowG result (List.foldl (varfixWalk rowG) accCand args)

                Mono.MList _ inner ->
                    varfixWalk rowG inner acc

                Mono.MTuple _ elems ->
                    List.foldl (varfixWalk rowG) acc elems

                Mono.MRecord _ fields ->
                    Dict.foldl (\_ ft a -> varfixWalk rowG ft a) acc fields

                Mono.MCustom _ _ _ args ->
                    List.foldl (varfixWalk rowG) acc args

                _ ->
                    acc

        -- The `LVar` slots an ungated union over constructor rows would turn into sets.
        varfixIsCtor rowKey =
            case rowKey of
                Mono.Global vfHome vfName ->
                    case HashMap.get TOpt.globalHash (==) (TOpt.Global vfHome vfName) sFinal.env.toptNodes of
                        Just (TOpt.Ctor _ _ _) ->
                            True

                        Just (TOpt.Box _) ->
                            True

                        _ ->
                            False

                _ ->
                    False

        varfixGname rowKey =
            case rowKey of
                Mono.Global _ vfName ->
                    vfName

                _ ->
                    "?"

        varfixCtorUnions =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( rowKey, mt ) ->
                            if varfixIsCtor rowKey then
                                Dict.update (varfixGname rowKey)
                                    (\v ->
                                        Just
                                            (case v of
                                                Just u ->
                                                    Mono.enrichAnnotations u mt

                                                Nothing ->
                                                    mt
                                            )
                                    )
                                    acc

                            else
                                acc

                        Nothing ->
                            acc
                )
                Dict.empty
                g.registry.reverseMapping

        varfixCountFlips ta tb =
            case ( ta, tb ) of
                ( Mono.MFunction _ annoA argsA resA, Mono.MFunction _ annoB argsB resB ) ->
                    (case ( annoA, annoB ) of
                        ( Mono.LVar _, Mono.LSet _ ) ->
                            1

                        _ ->
                            0
                    )
                        + varfixCountFlips resA resB
                        + List.sum (List.map2 varfixCountFlips argsA argsB)

                ( Mono.MList _ xa, Mono.MList _ xb ) ->
                    varfixCountFlips xa xb

                ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
                    List.sum (List.map2 varfixCountFlips xsa xsb)

                ( Mono.MRecord _ fa, Mono.MRecord _ fb ) ->
                    Dict.foldl
                        (\fk fta n ->
                            n
                                + (case Dict.get fk fb of
                                    Just ftb ->
                                        varfixCountFlips fta ftb

                                    Nothing ->
                                        0
                                  )
                        )
                        0
                        fa

                ( Mono.MCustom _ _ _ xsa, Mono.MCustom _ _ _ xsb ) ->
                    List.sum (List.map2 varfixCountFlips xsa xsb)

                _ ->
                    0

        varfixLine =
            let
                mA =
                    Array.foldl
                        (\entry acc ->
                            case entry of
                                Just ( rowKey, mt ) ->
                                    varfixWalk (varfixGname rowKey) mt acc

                                Nothing ->
                                    acc
                        )
                        { would1 = 0, wouldN = 0, beyond = 0, noSucc = 0, byG = Dict.empty }
                        g.registry.reverseMapping

                flips =
                    Array.foldl
                        (\entry n ->
                            case entry of
                                Just ( rowKey, mt ) ->
                                    if varfixIsCtor rowKey && Mono.hasTopAnno mt then
                                        case Dict.get (varfixGname rowKey) varfixCtorUnions of
                                            Just u ->
                                                n + varfixCountFlips mt (Mono.enrichAnnotations mt u)

                                            Nothing ->
                                                n

                                    else
                                        n

                                Nothing ->
                                    n
                        )
                        0
                        g.registry.reverseMapping

                topG =
                    Dict.toList mA.byG
                        |> List.sortBy (\( _, n ) -> negate n)
                        |> List.take 10
                        |> List.map (\( gn, n ) -> gn ++ "=" ++ String.fromInt n)
                        |> String.join " "
            in
            "varfix: mA|would1="
                ++ String.fromInt mA.would1
                ++ " mA|wouldN="
                ++ String.fromInt mA.wouldN
                ++ " mA|beyond="
                ++ String.fromInt mA.beyond
                ++ " mA|noSucc="
                ++ String.fromInt mA.noSucc
                ++ " hazard|fixBvarflip="
                ++ String.fromInt flips
                ++ "\nvarfixg: "
                ++ topG

        -- For each `LVar` under a set arrow: could the set's members' rows or closures fill it?
        vf3RowsByG =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( Mono.Global vHome vName, mt ) ->
                            Dict.update (TOpt.toComparableGlobal (TOpt.Global vHome vName))
                                (\v -> Just (mt :: Maybe.withDefault [] v))
                                acc

                        _ ->
                            acc
                )
                Dict.empty
                g.registry.reverseMapping

        vf3EmptyCell =
            { top = False, var = False, varShared = False, sets = Nothing }

        -- `LVar` ids met under an argument; one also met result-side is a parameter passed through.
        vf3ArgIds underArg t acc =
            case t of
                Mono.MFunction _ anno args result ->
                    let
                        acc1 =
                            case ( underArg, anno ) of
                                ( True, Mono.LVar n ) ->
                                    Dict.insert n () acc

                                _ ->
                                    acc
                    in
                    List.foldl (\a aa -> vf3ArgIds True a aa) (vf3ArgIds underArg result acc1) args

                Mono.MList _ inner ->
                    vf3ArgIds underArg inner acc

                Mono.MTuple _ elems ->
                    List.foldl (\e aa -> vf3ArgIds underArg e aa) acc elems

                Mono.MRecord _ fields ->
                    Dict.foldl (\_ ft aa -> vf3ArgIds underArg ft aa) acc fields

                Mono.MCustom _ _ _ args ->
                    List.foldl (\a aa -> vf3ArgIds underArg a aa) acc args

                _ ->
                    acc

        vf3CellWalk argIds path t acc =
            case t of
                Mono.MFunction _ anno args result ->
                    let
                        acc1 =
                            Dict.update path
                                (\v ->
                                    let
                                        c =
                                            Maybe.withDefault vf3EmptyCell v
                                    in
                                    Just
                                        (case anno of
                                            Mono.LTop _ ->
                                                { c | top = True }

                                            Mono.LVar n ->
                                                { c | var = True, varShared = c.varShared || Dict.member n argIds }

                                            Mono.LPartial _ ->
                                                { c | var = True }

                                            Mono.LSet ms ->
                                                { c | sets = Just (Mono.unionSortedInts ms (Maybe.withDefault [] c.sets)) }
                                        )
                                )
                                acc

                        accR =
                            vf3CellWalk argIds (path ++ "/r") result acc1
                    in
                    List.foldl (\( i, a ) aa -> vf3CellWalk argIds (path ++ "/a" ++ String.fromInt i) a aa)
                        accR
                        (List.indexedMap Tuple.pair args)

                Mono.MList _ inner ->
                    vf3CellWalk argIds (path ++ "/l") inner acc

                Mono.MTuple _ elems ->
                    List.foldl (\( i, e ) aa -> vf3CellWalk argIds (path ++ "/t" ++ String.fromInt i) e aa)
                        acc
                        (List.indexedMap Tuple.pair elems)

                Mono.MRecord _ fields ->
                    Dict.foldl (\fn ft aa -> vf3CellWalk argIds (path ++ "/f:" ++ fn) ft aa) acc fields

                Mono.MCustom _ _ _ args ->
                    List.foldl (\( i, a ) aa -> vf3CellWalk argIds (path ++ "/c" ++ String.fromInt i) a aa)
                        acc
                        (List.indexedMap Tuple.pair args)

                _ ->
                    acc

        vf3MergeCell ca cb =
            { top = ca.top || cb.top
            , var = ca.var || cb.var
            , varShared = ca.varShared || cb.varShared
            , sets =
                case ( ca.sets, cb.sets ) of
                    ( Just xs, Just ys ) ->
                        Just (Mono.unionSortedInts xs ys)

                    ( Just xs, Nothing ) ->
                        Just xs

                    ( Nothing, s ) ->
                        s
            }

        vf3MergeMaps a b =
            Dict.foldl
                (\k cell d -> Dict.update k (\v -> Just (vf3MergeCell (Maybe.withDefault vf3EmptyCell v) cell)) d)
                a
                b

        -- The path in a row of `X` where a `p|X|k` value's own type starts, after `k` arguments.
        vf3AlignPrefix t k prefix =
            if k <= 0 then
                Just ( prefix, False )

            else
                case t of
                    Mono.MFunction _ _ args result ->
                        let
                            j =
                                List.length args
                        in
                        if k >= j then
                            vf3AlignPrefix result (k - j) (prefix ++ "/r")

                        else
                            Just ( prefix, True )

                    _ ->
                        Nothing

        -- The cells of `gstr`'s rows as seen by a value with `k` arguments supplied, cached.
        vf3OffsetFor gstr k cache0 =
            let
                ck =
                    gstr ++ "#" ++ String.fromInt k
            in
            case Dict.get ck cache0 of
                Just cached ->
                    ( cached, cache0 )

                Nothing ->
                    let
                        built =
                            case Dict.get gstr vf3RowsByG of
                                Nothing ->
                                    Err "headNoRows"

                                Just rows ->
                                    List.foldl
                                        (\row acc ->
                                            case acc of
                                                Err e ->
                                                    Err e

                                                Ok ( cm, partial ) ->
                                                    case vf3AlignPrefix row k "" of
                                                        Nothing ->
                                                            Err "alignFail"

                                                        Just ( prefix, isPartial ) ->
                                                            let
                                                                plen =
                                                                    String.length prefix

                                                                rekeyed =
                                                                    Dict.foldl
                                                                        (\key cell d ->
                                                                            if String.startsWith prefix key then
                                                                                Dict.insert (String.dropLeft plen key) cell d

                                                                            else
                                                                                d
                                                                        )
                                                                        Dict.empty
                                                                        (vf3CellWalk (vf3ArgIds False row Dict.empty) "" row Dict.empty)
                                                            in
                                                            Ok ( vf3MergeMaps cm rekeyed, partial || isPartial )
                                        )
                                        (Ok ( Dict.empty, False ))
                                        rows
                    in
                    ( built, Dict.insert ck built cache0 )

        -- Closure body cells by member, as `lambdaHomesOf` builds them, with pass-through marked.
        vf3RecordLambda info body t acc =
            case info.lssMember of
                Just mid ->
                    let
                        bodyType =
                            Mono.typeOf body

                        argIds =
                            vf3ArgIds False t (vf3ArgIds False bodyType Dict.empty)

                        cells =
                            vf3CellWalk argIds "/r" bodyType Dict.empty
                    in
                    Dict.update mid
                        (\v ->
                            Just
                                (case v of
                                    Just cur ->
                                        vf3MergeMaps cur cells

                                    Nothing ->
                                        cells
                                )
                        )
                        acc

                Nothing ->
                    acc

        vf3DeciderExprs d acc =
            case d of
                Mono.Leaf (Mono.Inline e) ->
                    e :: acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ success failure ->
                    vf3DeciderExprs failure (vf3DeciderExprs success acc)

                Mono.FanOut _ tests fallback ->
                    vf3DeciderExprs fallback
                        (List.foldl (\( _, dd ) aa -> vf3DeciderExprs dd aa) acc tests)

        vf3ExprClosures e acc =
            case e of
                Mono.MonoClosure info body t ->
                    vf3ExprClosures body (vf3RecordLambda info body t acc)

                Mono.MonoList _ items _ ->
                    List.foldl vf3ExprClosures acc items

                Mono.MonoCall _ f args _ _ ->
                    List.foldl vf3ExprClosures (vf3ExprClosures f acc) args

                Mono.MonoTailCall _ entries _ ->
                    List.foldl (\( _, x ) aa -> vf3ExprClosures x aa) acc entries

                Mono.MonoIf branches final _ ->
                    vf3ExprClosures final
                        (List.foldl (\( c, th ) aa -> vf3ExprClosures th (vf3ExprClosures c aa)) acc branches)

                Mono.MonoLet def body _ ->
                    vf3ExprClosures body
                        (case def of
                            Mono.MonoDef _ bound ->
                                vf3ExprClosures bound acc

                            Mono.MonoTailDef _ _ bound ->
                                vf3ExprClosures bound acc
                        )

                Mono.MonoDestruct _ inner _ ->
                    vf3ExprClosures inner acc

                Mono.MonoCase _ _ decider branches _ ->
                    List.foldl (\( _, x ) aa -> vf3ExprClosures x aa)
                        (List.foldl vf3ExprClosures acc (vf3DeciderExprs decider []))
                        branches

                Mono.MonoRecordCreate fields _ ->
                    List.foldl (\( _, x ) aa -> vf3ExprClosures x aa) acc fields

                Mono.MonoRecordAccess inner _ _ ->
                    vf3ExprClosures inner acc

                Mono.MonoRecordUpdate inner updates _ ->
                    List.foldl (\( _, x ) aa -> vf3ExprClosures x aa) (vf3ExprClosures inner acc) updates

                Mono.MonoTupleCreate _ items _ ->
                    List.foldl vf3ExprClosures acc items

                _ ->
                    acc

        vf3LambdaHomes =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just (Mono.MonoDefine expr _) ->
                            vf3ExprClosures expr acc

                        Just (Mono.MonoTailFunc _ expr _) ->
                            vf3ExprClosures expr acc

                        Just (Mono.MonoPortIncoming expr _) ->
                            vf3ExprClosures expr acc

                        Just (Mono.MonoPortOutgoing expr _) ->
                            vf3ExprClosures expr acc

                        _ ->
                            acc
                )
                Dict.empty
                g.nodes

        -- Which kind of member supplied the cells: "" global or constructor, "p"/"pp", "l", or "mix".
        vf3TagJoin mtag t =
            case mtag of
                Nothing ->
                    Just t

                Just cur ->
                    if cur == t then
                        mtag

                    else
                        Just "mix"

        vf3AddRows gstr k cm mtag c0 =
            case vf3OffsetFor gstr k c0 of
                ( Err e, c1 ) ->
                    ( Err e, c1 )

                ( Ok ( rowCells, isPartial ), c1 ) ->
                    ( Ok
                        ( vf3MergeMaps cm rowCells
                        , vf3TagJoin mtag
                            (if k == 0 then
                                ""

                             else if isPartial then
                                "pp"

                             else
                                "p"
                            )
                        )
                    , c1
                    )

        vf3HeadCtx ms cache0 =
            let
                ( res, cacheEnd ) =
                    List.foldl
                        (\m ( acc, c ) ->
                            case acc of
                                Err e ->
                                    ( Err e, c )

                                Ok ( cm, mtag ) ->
                                    case Dict.get m memberKeyOf of
                                        Nothing ->
                                            ( Err "otherHead", c )

                                        Just mkey ->
                                            case String.split "|" mkey of
                                                "g" :: gstr :: _ ->
                                                    vf3AddRows gstr 0 cm mtag c

                                                "c" :: gstr :: _ ->
                                                    vf3AddRows gstr 0 cm mtag c

                                                "p" :: gstr :: dstr :: _ ->
                                                    case String.toInt dstr of
                                                        Just d ->
                                                            vf3AddRows gstr d cm mtag c

                                                        Nothing ->
                                                            ( Err "otherHead", c )

                                                "l" :: _ ->
                                                    case Dict.get m vf3LambdaHomes of
                                                        Just lcells ->
                                                            ( Ok ( vf3MergeMaps cm lcells, vf3TagJoin mtag "l" ), c )

                                                        Nothing ->
                                                            ( Err "lNoRecord", c )

                                                _ ->
                                                    ( Err "otherHead", c )
                        )
                        ( Ok ( Dict.empty, Nothing ), cache0 )
                        ms
            in
            ( Result.map (\( cm, mtag ) -> ( cm, Maybe.withDefault "" mtag )) res, cacheEnd )

        vf3Bump cls tally =
            { tally | cls = Dict.update cls (\v -> Just (1 + Maybe.withDefault 0 v)) tally.cls }

        vf3Scan rowG t ctx ( tally, cache ) =
            case t of
                Mono.MFunction _ anno args result ->
                    let
                        tally1 =
                            case anno of
                                Mono.LVar _ ->
                                    case ctx of
                                        Nothing ->
                                            vf3Bump "noHead" tally

                                        Just ( Err cls, _ ) ->
                                            vf3Bump cls tally

                                        Just ( Ok ( cm, tag ), rp ) ->
                                            case Dict.get rp cm of
                                                Nothing ->
                                                    vf3Bump (tag ++ "shapeMiss") tally

                                                Just cell ->
                                                    if cell.top then
                                                        vf3Bump (tag ++ "contamTop") tally

                                                    else if cell.var then
                                                        -- Shared: the same variable also appears under an argument of the row.
                                                        vf3Bump
                                                            (tag
                                                                ++ (if cell.varShared then
                                                                        "contamVarShared"

                                                                    else
                                                                        "contamVarIso"
                                                                   )
                                                            )
                                                            tally

                                                    else
                                                        case cell.sets of
                                                            Just _ ->
                                                                let
                                                                    t2 =
                                                                        vf3Bump (tag ++ "would") tally
                                                                in
                                                                { t2 | byG = Dict.update (tag ++ "|" ++ rowG) (\v -> Just (1 + Maybe.withDefault 0 v)) t2.byG }

                                                            Nothing ->
                                                                vf3Bump (tag ++ "noInfo") tally

                                _ ->
                                    tally

                        ( resultCtx, cache1 ) =
                            case anno of
                                Mono.LSet ms ->
                                    let
                                        ( r, c ) =
                                            vf3HeadCtx ms cache
                                    in
                                    ( Just ( r, "/r" ), c )

                                _ ->
                                    ( Maybe.map (\( r, p ) -> ( r, p ++ "/r" )) ctx, cache )

                        acc2 =
                            vf3Scan rowG result resultCtx ( tally1, cache1 )
                    in
                    List.foldl (\a aa -> vf3Scan rowG a Nothing aa) acc2 args

                Mono.MList _ inner ->
                    vf3Scan rowG inner (Maybe.map (\( r, p ) -> ( r, p ++ "/l" )) ctx) ( tally, cache )

                Mono.MTuple _ elems ->
                    List.foldl
                        (\( i, e ) aa -> vf3Scan rowG e (Maybe.map (\( r, p ) -> ( r, p ++ "/t" ++ String.fromInt i )) ctx) aa)
                        ( tally, cache )
                        (List.indexedMap Tuple.pair elems)

                Mono.MRecord _ fields ->
                    Dict.foldl
                        (\fn ft aa -> vf3Scan rowG ft (Maybe.map (\( r, p ) -> ( r, p ++ "/f:" ++ fn )) ctx) aa)
                        ( tally, cache )
                        fields

                Mono.MCustom _ _ _ args ->
                    List.foldl
                        (\( i, a ) aa -> vf3Scan rowG a (Maybe.map (\( r, p ) -> ( r, p ++ "/c" ++ String.fromInt i )) ctx) aa)
                        ( tally, cache )
                        (List.indexedMap Tuple.pair args)

                _ ->
                    ( tally, cache )

        -- Singleton `l|` arrows whose result is still an `LVar`, by the closure's parameter count.
        m2Homes =
            lambdaHomesOf g.nodes

        m2StageWalk t acc =
            case t of
                Mono.MFunction _ anno args result ->
                    let
                        acc1 =
                            case ( anno, result ) of
                                ( Mono.LSet [ m ], Mono.MFunction _ (Mono.LVar _) _ _ ) ->
                                    case Dict.get m memberKeyOf of
                                        Just mk ->
                                            if String.startsWith "l|" mk then
                                                case Dict.get m m2Homes of
                                                    Just home ->
                                                        case home.arity of
                                                            Just a2 ->
                                                                if a2 >= 2 then
                                                                    { acc | stageVar = acc.stageVar + 1 }

                                                                else
                                                                    { acc | bodyVar = acc.bodyVar + 1 }

                                                            Nothing ->
                                                                { acc | arityMix = acc.arityMix + 1 }

                                                    Nothing ->
                                                        { acc | noHome = acc.noHome + 1 }

                                            else
                                                acc

                                        Nothing ->
                                            acc

                                _ ->
                                    acc
                    in
                    List.foldl m2StageWalk (m2StageWalk result acc1) args

                Mono.MList _ inner ->
                    m2StageWalk inner acc

                Mono.MTuple _ elems ->
                    List.foldl m2StageWalk acc elems

                Mono.MRecord _ fields ->
                    Dict.foldl (\_ ft a -> m2StageWalk ft a) acc fields

                Mono.MCustom _ _ _ args ->
                    List.foldl m2StageWalk acc args

                _ ->
                    acc

        m2StageLine =
            let
                t =
                    Array.foldl
                        (\entry acc ->
                            case entry of
                                Just ( _, mt ) ->
                                    m2StageWalk mt acc

                                Nothing ->
                                    acc
                        )
                        { stageVar = 0, bodyVar = 0, arityMix = 0, noHome = 0 }
                        g.registry.reverseMapping
            in
            "m2stage: stageVar="
                ++ String.fromInt t.stageVar
                ++ " bodyVar="
                ++ String.fromInt t.bodyVar
                ++ " arityMix="
                ++ String.fromInt t.arityMix
                ++ " noHome="
                ++ String.fromInt t.noHome

        varfix3Line =
            let
                ( vf3T, _ ) =
                    Array.foldl
                        (\entry acc ->
                            case entry of
                                Just ( rowKey, mt ) ->
                                    vf3Scan
                                        (case rowKey of
                                            Mono.Global _ vf3n ->
                                                vf3n

                                            _ ->
                                                "?"
                                        )
                                        mt
                                        Nothing
                                        acc

                                Nothing ->
                                    acc
                        )
                        ( { cls = Dict.empty, byG = Dict.empty }, Dict.empty )
                        g.registry.reverseMapping

                clsLine =
                    Dict.toList vf3T.cls
                        |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                        |> String.join " "

                gLine =
                    Dict.toList vf3T.byG
                        |> List.sortBy (\( _, n ) -> negate n)
                        |> List.take 12
                        |> List.map (\( gn, n ) -> gn ++ "=" ++ String.fromInt n)
                        |> String.join " "
            in
            "varfix3: "
                ++ clsLine
                ++ "\nvarfix3g: "
                ++ gLine
                ++ "\nvarlam: midsRecorded="
                ++ String.fromInt (Dict.size vf3LambdaHomes)
                ++ " withArrowResult="
                ++ String.fromInt
                    (Dict.foldl
                        (\_ cm n ->
                            if Dict.member "/r" cm then
                                n + 1

                            else
                                n
                        )
                        0
                        vf3LambdaHomes
                    )
                ++ " cleanResult="
                ++ String.fromInt
                    (Dict.foldl
                        (\_ cm n ->
                            case Dict.get "/r" cm of
                                Just cell ->
                                    if not cell.top && not cell.var && cell.sets /= Nothing then
                                        n + 1

                                    else
                                        n

                                Nothing ->
                                    n
                        )
                        0
                        vf3LambdaHomes
                    )
                ++ " contamResult="
                ++ String.fromInt
                    (Dict.foldl
                        (\_ cm n ->
                            case Dict.get "/r" cm of
                                Just cell ->
                                    if cell.top || cell.var then
                                        n + 1

                                    else
                                        n

                                Nothing ->
                                    n
                        )
                        0
                        vf3LambdaHomes
                    )

        -- Each remaining `LVar` position against its global's signature: trivial, or fewer arrows.
        sigArrowCountOf t n =
            case t of
                Mono.MFunction _ _ args result ->
                    List.foldl (\a acc -> sigArrowCountOf a acc)
                        (sigArrowCountOf result (n + 1))
                        args

                Mono.MList _ inner ->
                    sigArrowCountOf inner n

                Mono.MTuple _ elems ->
                    List.foldl (\e acc -> sigArrowCountOf e acc) n elems

                Mono.MRecord _ fields ->
                    Dict.foldl (\_ ft acc -> sigArrowCountOf ft acc) n fields

                Mono.MCustom _ _ _ args ->
                    List.foldl (\a acc -> sigArrowCountOf a acc) n args

                _ ->
                    n

        sigVarCountOf t n =
            case t of
                Mono.MFunction _ anno args result ->
                    List.foldl (\a acc -> sigVarCountOf a acc)
                        (sigVarCountOf result
                            (case anno of
                                Mono.LVar _ ->
                                    n + 1

                                _ ->
                                    n
                            )
                        )
                        args

                Mono.MList _ inner ->
                    sigVarCountOf inner n

                Mono.MTuple _ elems ->
                    List.foldl (\e acc -> sigVarCountOf e acc) n elems

                Mono.MRecord _ fields ->
                    Dict.foldl (\_ ft acc -> sigVarCountOf ft acc) n fields

                Mono.MCustom _ _ _ args ->
                    List.foldl (\a acc -> sigVarCountOf a acc) n args

                _ ->
                    n

        sigfactLine =
            let
                tallied =
                    Array.foldl
                        (\entry acc ->
                            case entry of
                                Just ( Mono.Global sfHome sfName, mt ) ->
                                    let
                                        nvar =
                                            sigVarCountOf mt 0
                                    in
                                    if nvar == 0 then
                                        acc

                                    else
                                        let
                                            nRowArrows =
                                                sigArrowCountOf mt 0

                                            bump k n a =
                                                Dict.update k (\v -> Just (n + Maybe.withDefault 0 v)) a

                                            perG =
                                                Dict.update sfName
                                                    (\v ->
                                                        let
                                                            cur =
                                                                Maybe.withDefault { vars = 0, rows = 0 } v
                                                        in
                                                        Just { vars = cur.vars + nvar, rows = cur.rows + 1 }
                                                    )
                                                    acc.perG
                                        in
                                        case HashMap.get TOpt.globalHash (==) (TOpt.Global sfHome sfName) sFinal.lssSignatures of
                                            Nothing ->
                                                { acc | cells = bump "noSig" nvar acc.cells, perG = perG }

                                            Just sig ->
                                                let
                                                    nSigArrows =
                                                        Array.length sig.arrows

                                                    factArrows =
                                                        Array.foldl
                                                            (\f n ->
                                                                if f.members /= [] || f.top then
                                                                    n + 1

                                                                else
                                                                    n
                                                            )
                                                            0
                                                            sig.arrows

                                                    shapeTag =
                                                        if nRowArrows > nSigArrows then
                                                            "|extra"

                                                        else
                                                            "|eq"

                                                    sigTag =
                                                        if sig.trivial then
                                                            "trivial"

                                                        else
                                                            "facts"

                                                    cells1 =
                                                        bump (sigTag ++ shapeTag) nvar acc.cells

                                                    cells2 =
                                                        if not sig.trivial && List.isEmpty sig.residual then
                                                            bump "factsNoQ" nvar cells1

                                                        else
                                                            cells1

                                                    cells3 =
                                                        if not sig.trivial && factArrows == 0 then
                                                            bump "factsRepOnly" nvar cells2

                                                        else
                                                            cells2
                                                in
                                                { acc | cells = cells3, perG = perG }

                                Just ( Mono.Accessor _, mt ) ->
                                    let
                                        nvar =
                                            sigVarCountOf mt 0
                                    in
                                    if nvar == 0 then
                                        acc

                                    else
                                        { acc
                                            | cells =
                                                Dict.update "accessorRow"
                                                    (\v -> Just (nvar + Maybe.withDefault 0 v))
                                                    acc.cells
                                        }

                                Nothing ->
                                    acc
                        )
                        { cells = Dict.empty, perG = Dict.empty }
                        g.registry.reverseMapping

                cellsLine =
                    Dict.toList tallied.cells
                        |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                        |> String.join " "

                topLine =
                    Dict.toList tallied.perG
                        |> List.sortBy (\( _, r ) -> negate r.vars)
                        |> List.take 10
                        |> List.map
                            (\( gn, r ) ->
                                let
                                    -- Detail comes from the first signature whose global's key ends in the name.
                                    sigDesc =
                                        HashMap.foldl
                                            (\kg sig found ->
                                                if found == "" && String.endsWith ("." ++ gn) (TOpt.toComparableGlobal kg) then
                                                    (if sig.trivial then
                                                        "triv"

                                                     else
                                                        "facts"
                                                    )
                                                        ++ ":"
                                                        ++ String.fromInt (Array.length sig.arrows)
                                                        ++ "a/"
                                                        ++ String.fromInt (List.length sig.residual)
                                                        ++ "q"

                                                else
                                                    found
                                            )
                                            ""
                                            sFinal.lssSignatures
                                in
                                gn
                                    ++ "="
                                    ++ String.fromInt r.vars
                                    ++ "("
                                    ++ (if sigDesc == "" then
                                            "noSig"

                                        else
                                            sigDesc
                                       )
                                    ++ ")"
                            )
                        |> String.join " "
            in
            "sigfact: " ++ cellsLine ++ "\nsigfactg: " ++ topLine

        -- Each ⊤ position of the final registry, classified by the kind of node its global is.
        topSiteClassOf key =
            case key of
                Mono.Global tsHome tsName ->
                    topSiteClassOfGlobal (TOpt.Global tsHome tsName)

                _ ->
                    "accessor"

        topSiteClassOfGlobal tsGlobal =
            case HashMap.get TOpt.globalHash (==) tsGlobal sFinal.env.toptNodes of
                Nothing ->
                    "none"

                Just node ->
                    case LssInfer.kernelAliasOf tsGlobal sFinal of
                        Just ( kPrefix, kHome, kName ) ->
                            if licensedKernelAliasNode node sFinal then
                                "licAlias"

                            else
                                case KernelSetFacts.factFor kPrefix kHome kName of
                                    Just _ ->
                                        "refAlias"

                                    Nothing ->
                                        "unlicAlias"

                        Nothing ->
                            case node of
                                TOpt.Define _ _ _ ->
                                    "elm"

                                TOpt.TrackedDefine _ _ _ _ ->
                                    "elm"

                                TOpt.Cycle _ _ _ _ ->
                                    "cycle"

                                TOpt.Ctor _ _ _ ->
                                    "ctor"

                                TOpt.Enum _ _ ->
                                    "ctor"

                                TOpt.Box _ ->
                                    "ctor"

                                TOpt.Kernel _ _ ->
                                    "kernelDef"

                                TOpt.Manager _ ->
                                    "manager"

                                TOpt.PortIncoming _ _ _ ->
                                    "port"

                                TOpt.PortOutgoing _ _ _ ->
                                    "port"

                                TOpt.Link target ->
                                    topSiteClassOfGlobal target

        topPosClassOf pth =
            if pth == "" then
                "head"

            else if List.all (\seg -> seg == "r") (List.filter (\x -> x /= "") (String.split "/" pth)) then
                "spine"

            else
                "nested"

        topSiteAndKindCounts =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( key, monoType ) ->
                            case List.filter (\( _, kind ) -> String.startsWith "top" kind) (posWalk "" monoType []) of
                                [] ->
                                    acc

                                tops ->
                                    let
                                        cls =
                                            topSiteClassOf key
                                    in
                                    List.foldl
                                        (\( pth, kindTag ) ( accSite, accKind ) ->
                                            let
                                                kindLabel =
                                                    String.dropLeft 4 kindTag

                                                bump k d =
                                                    Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d
                                            in
                                            ( bump (cls ++ "|" ++ topPosClassOf pth) accSite
                                            , bump (kindLabel ++ "|" ++ cls) accKind
                                            )
                                        )
                                        acc
                                        tops

                        Nothing ->
                            acc
                )
                ( Dict.empty, Dict.empty )
                g.registry.reverseMapping

        -- Each ⊤ in a constructor row, against what the union of that constructor's rows holds.
        ctorGlobalKeyOf key =
            case key of
                Mono.Global cgHome cgName ->
                    if topSiteClassOf key == "ctor" then
                        Just (TOpt.toComparableGlobal (TOpt.Global cgHome cgName))

                    else
                        Nothing

                _ ->
                    Nothing

        ctorUnions =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( key, monoType ) ->
                            case ctorGlobalKeyOf key of
                                Just gk ->
                                    Dict.update gk
                                        (\v ->
                                            Just
                                                (case v of
                                                    Just u ->
                                                        Mono.enrichAnnotations u monoType

                                                    Nothing ->
                                                        monoType
                                                )
                                        )
                                        acc

                                Nothing ->
                                    acc

                        Nothing ->
                            acc
                )
                Dict.empty
                g.registry.reverseMapping

        destrBendCounts =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( key, monoType ) ->
                            case ctorGlobalKeyOf key of
                                Just gk ->
                                    case Dict.get gk ctorUnions of
                                        Just u ->
                                            countTopCells monoType u acc

                                        Nothing ->
                                            acc

                                Nothing ->
                                    acc

                        Nothing ->
                            acc
                )
                ( 0, 0, 0 )
                g.registry.reverseMapping

        countTopCells a b acc =
            case ( a, b ) of
                ( Mono.MFunction _ annoA argsA retA, Mono.MFunction _ annoB argsB retB ) ->
                    if List.length argsA == List.length argsB then
                        List.foldl (\( x, y ) ac -> countTopCells x y ac)
                            (countTopCells retA retB (countTopCell annoA annoB acc))
                            (List.map2 Tuple.pair argsA argsB)

                    else
                        acc

                ( Mono.MList _ xa, Mono.MList _ xb ) ->
                    countTopCells xa xb acc

                ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
                    if List.length xsa == List.length xsb then
                        List.foldl (\( x, y ) ac -> countTopCells x y ac) acc (List.map2 Tuple.pair xsa xsb)

                    else
                        acc

                ( Mono.MRecord _ fa, Mono.MRecord _ fb ) ->
                    Dict.foldl
                        (\k va ac ->
                            case Dict.get k fb of
                                Just vb ->
                                    countTopCells va vb ac

                                Nothing ->
                                    ac
                        )
                        acc
                        fa

                ( Mono.MCustom _ _ _ xsa, Mono.MCustom _ _ _ xsb ) ->
                    if List.length xsa == List.length xsb then
                        List.foldl (\( x, y ) ac -> countTopCells x y ac) acc (List.map2 Tuple.pair xsa xsb)

                    else
                        acc

                _ ->
                    acc

        countTopCell annoA annoB acc =
            let
                ( nK1, nKN, nNo ) =
                    acc
            in
            case ( annoA, annoB ) of
                ( Mono.LTop _, Mono.LSet [ _ ] ) ->
                    ( nK1 + 1, nKN, nNo )

                ( Mono.LTop _, Mono.LSet _ ) ->
                    ( nK1, nKN + 1, nNo )

                ( Mono.LTop _, _ ) ->
                    ( nK1, nKN, nNo + 1 )

                _ ->
                    acc

        destrBendLine =
            let
                ( bK1, bKN, bNo ) =
                    destrBendCounts
            in
            "destrBend: k1=" ++ String.fromInt bK1 ++ " kN=" ++ String.fromInt bKN ++ " no=" ++ String.fromInt bNo

        topSiteLine =
            "top sites: "
                ++ String.join " "
                    (List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
                        (Dict.toList (Tuple.first topSiteAndKindCounts))
                    )

        topKindLine =
            "top kinds: "
                ++ String.join " "
                    (List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
                        (Dict.toList (Tuple.second topSiteAndKindCounts))
                    )

        -- How many settled `LVar` arrows some call applies; `controlBp` is the same for set arrows.
        livenessLine =
            let
                applied =
                    stats.sigStats.appliedArrows

                countIn arrows =
                    Dict.foldl
                        (\akey _ n ->
                            if Dict.member akey applied then
                                n + 1

                            else
                                n
                        )
                        0
                        arrows

                varApplied =
                    countIn settled.varArrows

                setApplied =
                    countIn settled.setArrows

                bp num den =
                    if den <= 0 then
                        0

                    else
                        (10000 * num) // den
            in
            "liveness: attempts="
                ++ String.fromInt (censusAt "apply|attempt")
                ++ " hit="
                ++ String.fromInt (censusAt "apply|hit")
                ++ " noSlot="
                ++ String.fromInt (censusAt "apply|noSlot")
                ++ " noArrowId="
                ++ String.fromInt (censusAt "apply|noArrowId")
                ++ " hitBp="
                ++ String.fromInt (bp (censusAt "apply|hit") (censusAt "apply|attempt"))
                ++ " | appliedArrows="
                ++ String.fromInt (Dict.size applied)
                ++ " varArrows="
                ++ String.fromInt (Dict.size settled.varArrows)
                ++ " varApplied="
                ++ String.fromInt varApplied
                ++ " setArrows="
                ++ String.fromInt (Dict.size settled.setArrows)
                ++ " setApplied="
                ++ String.fromInt setApplied
                ++ " liveBp="
                ++ String.fromInt (bp varApplied (Dict.size settled.varArrows))
                ++ " controlBp="
                ++ String.fromInt (bp setApplied (Dict.size settled.setArrows))

        -- Arrows that got no solver-root stamp; RECONCILES compares them with all `ArrowId`s drawn.
        stampWalkLine =
            let
                lost =
                    sFinal.env.stampArrowsInNone + sFinal.env.stampArrowsUnstampedInPartial

                expected =
                    sFinal.env.arrowTotal
            in
            "stampwalk: types="
                ++ String.fromInt
                    (sFinal.env.stampTypesAll + sFinal.env.stampTypesNone + sFinal.env.stampTypesPartial)
                ++ " all="
                ++ String.fromInt sFinal.env.stampTypesAll
                ++ " none="
                ++ String.fromInt sFinal.env.stampTypesNone
                ++ " partial="
                ++ String.fromInt sFinal.env.stampTypesPartial
                ++ " | arrowsNone="
                ++ String.fromInt sFinal.env.stampArrowsInNone
                ++ " arrowsPartialUnstamped="
                ++ String.fromInt sFinal.env.stampArrowsUnstampedInPartial
                ++ " lostTotal="
                ++ String.fromInt lost
                ++ " expected="
                ++ String.fromInt expected
                ++ " RECONCILES="
                ++ (if lost == expected then
                        "yes"

                    else
                        "NO"
                   )

        ledgerLine =
            "ledger: k1="
                ++ String.fromInt ledgerK1
                ++ " kN="
                ++ String.fromInt ledgerKN
                ++ " overcap="
                ++ String.fromInt stats.widenedBySize
                ++ " top="
                ++ String.fromInt ledgerTop
                ++ " var="
                ++ String.fromInt ledgerUnknown
                ++ " total="
                ++ String.fromInt stats.setsZonked
                ++ " RECONCILES="
                ++ (if ledgerSum == stats.setsZonked then
                        "yes"

                    else
                        "NO(" ++ String.fromInt ledgerSum ++ ")"
                   )
    in
    String.join "\n"
        ([ "=== LSS census ==="
         , "members: " ++ String.fromInt sFinal.nextMemberId ++ " total (" ++ String.fromInt lambdaCount ++ " source lambdas, " ++ String.fromInt internedCount ++ " interned)"
         , "signatures: " ++ String.fromInt sigCount ++ " memoized (" ++ String.fromInt trivialCount ++ " trivial)"
         , "sets zonked: " ++ String.fromInt stats.setsZonked ++ "; size histogram: " ++ histLine
         , coverageLine
         , ledgerLine
         , settledLine
         ]
            -- Each block is printed only when its flag is on (lss.arrowCensus, lss.qCensus).
            ++ (if sFinal.env.lss.arrowCensus then
                    [ stampWalkLine, livenessLine, topSiteLine, topKindLine, destrBendLine, varfixLine, varfix3Line, sigfactLine, m2StageLine, posLine ]

                else
                    []
               )
            ++ (if sFinal.env.lss.qCensus then
                    [ qInferLine, qLine, qSampleLines ]

                else
                    []
               )
            ++ [ settledArrowLine
               , "widened: bySize=" ++ String.fromInt stats.widenedBySize ++ " byKernel=" ++ String.fromInt stats.widenedByKernel ++ " byBudget=" ++ String.fromInt stats.widenedByBudget ++ " bySigSize=" ++ String.fromInt stats.sigStats.widenedBySigSize
               , "widened sizes: " ++ widenedHistLine
               , "join flush: rounds=" ++ String.fromInt stats.joinRounds ++ " retranslations=" ++ String.fromInt stats.retranslations
               , "set-writes: skip=" ++ String.fromInt stats.setWriteSkip ++ " flex=" ++ String.fromInt stats.setWriteFlex ++ " topJoin=" ++ String.fromInt stats.setWriteTopJoin ++ " union=" ++ String.fromInt stats.setWriteUnion ++ " slotsMinted=" ++ String.fromInt stats.slotsMinted
               , "joins: identical=" ++ String.fromInt stats.joinIdenticalHit ++ " noop=" ++ String.fromInt stats.joinNoop ++ " changed=" ++ String.fromInt stats.joinChanged ++ " completion=" ++ String.fromInt stats.completionJoins ++ " completionNoop=" ++ String.fromInt stats.completionJoinNoop
               , "devirtDirect=" ++ String.fromInt stats.devirtDirect ++ " devirtKernel=" ++ String.fromInt stats.devirtKernel ++ " unqualifiedLambdaMints=" ++ String.fromInt stats.unqualifiedLambdaMints
               , "muTie: tied=" ++ String.fromInt (Dict.size sFinal.lssMemberTable.muTied) ++ " qualifiedRecorded=" ++ String.fromInt (Dict.size sFinal.lssMemberTable.lambdaQualified)
               , "grounding: grounded=" ++ String.fromInt stats.grounding.grounded ++ " deferred=" ++ String.fromInt stats.grounding.deferred
               , "layoutQual: mints=" ++ String.fromInt stats.layoutQual.mints ++ " shared=" ++ String.fromInt stats.layoutQual.shared ++ " fallback=" ++ String.fromInt stats.layoutQual.fallback ++ " tieBypass=" ++ String.fromInt stats.layoutQual.tieBypass
               , "instanceQual: applied=" ++ String.fromInt stats.layoutQual.instApplied ++ " capped=" ++ String.fromInt stats.layoutQual.instCapped ++ " rootSkip=" ++ String.fromInt stats.layoutQual.instRootSkip
               , "sigflow: widenedByCf=" ++ String.fromInt stats.sigStats.widenedByCf ++ " kernelFactHits=" ++ String.fromInt stats.sigStats.kernelFactHits ++ " kernelLicensed=" ++ String.fromInt stats.sigStats.kernelLicensed ++ " edges=" ++ String.fromInt stats.sigStats.edgesInstalled ++ " degraded=" ++ String.fromInt stats.sigStats.flowDegraded
               , "honestSources: topMixedFlex=" ++ String.fromInt stats.sigStats.topMixedFlexSig ++ "/" ++ String.fromInt stats.sigStats.topMixedFlexDemand

               -- Distinct arrows with a multi-member set, beside the number of such read-backs.
               , "multisets: arrows=" ++ String.fromInt (Dict.size stats.sigStats.multiSetsByArrow) ++ " readbacks=" ++ String.fromInt ledgerKN ++ " byK=" ++ multiSetArrowHist
               , argFlowCensusBlock stats.sigStats.argFlowCensus
               , multiSetCensusBlock stats.sigStats.multiSetsByArrow sFinal.lssMemberTable
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
        )


{-| Returns one `MSET` line per arrow in `byArrow`, a table of arrow ids to the
members of the multi-member sets read back at them: the arrow id, the number of
members and their keys joined by `|`, tab-separated, in arrow-id order. A member
with no key is shown as `?` and its id. An empty table gives the single line
`MSET`, `(none)`, `0`, tab-separated with a trailing tab.

Members are shown by key rather than by id because ids are numbered in the
order they are minted.

-}
multiSetCensusBlock : Dict.Dict Int (List Int) -> Engine.LssMemberTable -> String
multiSetCensusBlock byArrow memberTable =
    if Dict.isEmpty byArrow then
        "MSET\t(none)\t0\t"

    else
        let
            keyOf =
                Dict.foldl (\k mid acc -> Dict.insert mid k acc) Dict.empty memberTable.byKey
        in
        String.join "\n"
            (List.map
                (\( akey, members ) ->
                    "MSET\t"
                        ++ String.fromInt akey
                        ++ "\t"
                        ++ String.fromInt (List.length members)
                        ++ "\t"
                        ++ String.join "|" (List.map (\m -> Maybe.withDefault ("?" ++ String.fromInt m) (Dict.get m keyOf)) members)
                )
                (Dict.toList byArrow)
            )


{-| Returns one `ARGF` line per census key, with its count, tab-separated and
sorted by key, or the single line `ARGF (none) 0` for an empty census.
-}
argFlowCensusBlock : Dict.Dict String Int -> String
argFlowCensusBlock census =
    if Dict.isEmpty census then
        "ARGF\t(none)\t0"

    else
        String.join "\n"
            (List.map (\( k, v ) -> "ARGF\t" ++ k ++ "\t" ++ String.fromInt v)
                (List.sortBy Tuple.first (Dict.toList census))
            )



-- ====== INITIAL STATE ======


{-| Returns the engine state before any spec exists, for an entry point in
`currentModule`. The type-variable supply continues from the assignment's next
id and the member-id supply from its next source-lambda id, so no member id
equals a source lambda's id. The super table starts as the assignment's.
-}
initState : Config.LssConfig -> Config.SpecLimits -> ModuleName.Canonical -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> AssignMVarIds.GlobalMVarState -> S
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
    , lssSignatures = HashMap.empty
    , lssInProgress = HashMap.empty
    , lssMemberTable = Engine.emptyMemberTable
    , nextMemberId = Id.toComparable mvarState.nextLam
    , lssStats = Engine.emptyLssStats
    , monoMemo = Engine.emptyMonoMemo
    , nodeResolution = Dict.empty
    , intern = Intern.empty
    , env =
        { -- A hash map, so a lookup builds no comparable string.
          toptNodes =
            DMap.foldl
                (\g node acc -> HashMap.insert TOpt.globalHash (==) g node acc)
                HashMap.empty
                nodes
        , annotations = annotations
        , globalTypeEnv = globalTypeEnv
        , currentModule = currentModule
        , superStatic = mvarState.superVars
        , lss = lssConfig
        , lamLabels = mvarState.lamLabels

        -- How many `ArrowId`s the assignment drew.
        , arrowTotal =
            Id.toComparable mvarState.nextArrow - Id.toComparable TypeIds.firstArrowId
        , stampTypesAll = mvarState.typesAll
        , stampTypesNone = mvarState.typesNone
        , stampTypesPartial = mvarState.typesPartial
        , stampArrowsInNone = mvarState.arrowsInNone
        , stampArrowsUnstampedInPartial = mvarState.arrowsUnstampedInPartial
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


{-| Returns the `SpecId` of `global` at `monoType`, and the state with that spec
scheduled at the head of the worklist.

The spec is created in the registry directly, not through
`Engine.enqueueSpec`, so no spec limit is checked for it. With LSS on its
annotation-widened key is recorded, which the lambdas minted in its body are
qualified by (see `Engine.lambdaInstanceMemberId`).

-}
seedSpec : Mono.Global -> Mono.MonoType -> S -> ( Mono.SpecId, S )
seedSpec global monoType s =
    let
        ( specId, reg1 ) =
            Registry.getOrCreateSpecId global monoType s.registry

        s1 =
            if s.env.lss.enabled then
                Engine.recordSpecWidenedKey specId
                    (Mono.toComparableMonoType (Mono.widenSets monoType))
                    s

            else
                s
    in
    ( specId
    , { s1
        | registry = reg1
        , worklist = SpecializeGlobal specId :: s1.worklist
        , scheduled = BitSet.insertGrowing specId s1.scheduled
      }
    )


{-| Returns the flags decoder's `SpecId`, seeded like the entry point at its
annotation type with its own spine stamped, and the state with it scheduled.
Returns `Nothing` when there is no flags decoder or its node is not a `Define`
or `TrackedDefine`.
-}
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
                            case Translate.stampSelfSpine flagsGlobal decoderMonoType s of
                                ( stampedDec, sb ) ->
                                    seedSpec (toptToMonoGlobal flagsGlobal) stampedDec sb
                    in
                    ( Just specId, s1 )



-- ====== WORKLIST DRAIN ======


{-| Returns the state once every work item has been translated, or the first
failure.

Items are taken from the head of the worklist, so the spec scheduled last is
translated first. After each item, a watchdog failure the item recorded ends the
drain. When the worklist is empty and some specs are dirty, a flush round puts
all of them back on the worklist; starting a round once `maxJoinRounds` have run
is an `EngineBug`, which names up to five of the dirty specs.

-}
drain : S -> Result Failure S
drain s =
    case s.worklist of
        [] ->
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
                    case s1.itemAux.pendingFailure of
                        Just f ->
                            Err f

                        Nothing ->
                            drain s1


{-| The number of flush rounds a drain may run; needing another is an
`EngineBug`.
-}
maxJoinRounds : Int
maxJoinRounds =
    100


{-| Returns the state after translating the spec `specId`: its node stored and
its registry type updated.

A spec that already has a node is skipped unless it is dirty. A dirty one is
translated again with its stored type, except one whose node has no body (see
`nodeSupportsRetranslation`), which keeps its node. An accessor spec becomes a
one-parameter function reading the field from its record argument. A global
with no node in the graph becomes a `MonoExtern`.

After translation, the item's `number` constraints are added to the super table
as `Engine.harvestSuperTableExcept` describes, leaving out the global's own
annotation variables, and accessor values in the node are resolved
(`ResolveAccessorValues.rewriteNode`). For a node with a body the registry type
becomes the node's type, or with LSS on the join of the node's type with the
stored type, so that no member a demand brought is dropped; at a licensed
kernel alias (`licensedKernelAliasNode`) a ⊤ the join produced where the stored
type had a set takes that set back, and the global's own spine is stamped on the
joined type again. A node without a body leaves the stored type as it is: for
a constructor, the node's type is the value it builds, not the function type
that was demanded.

-}
processItem : Mono.SpecId -> S -> Result Failure S
processItem specId s =
    if BitSet.member specId s.inProgress then
        Ok s

    else if nodeAlreadyDone specId s && not (BitSet.member specId s.dirtySpecs) then
        -- Already translated and not dirty: a repeated work item.
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

                                -- A join made during this translation marks the spec dirty again.
                                , dirtySpecs = BitSet.removeGrowing specId s.dirtySpecs
                            }

                    auxR =
                        sItemR.itemAux

                    -- Set after `resetItem`, which rebuilds `itemAux`.
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
                            ( resolution, sItem2 ) =
                                resolveGlobalNode home name sItem
                        in
                        case resolution.node of
                            Nothing ->
                                Ok (finishNode specId (Mono.MonoExtern monoType) sItem2)

                            Just node ->
                                if nodeAlreadyDone specId s && not (nodeSupportsRetranslation node) then
                                    -- A node without a body keeps its node; the dirty mark is already consumed.
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
                                                -- The global's own annotation variables are left out: each spec binds them differently.
                                                s1 =
                                                    Engine.harvestSuperTableExcept resolution.annIds s1raw

                                                ( monoNode, newLambdaCounter ) =
                                                    ResolveAccessorValues.rewriteNode home s1.lambdaCounter monoNode0

                                                actualType =
                                                    Mono.nodeType monoNode

                                                completionJoin =
                                                    if s1.env.lss.enabled && nodeSupportsRetranslation node then
                                                        case Registry.lookupSpecKey specId s1.registry of
                                                            Just ( specKey, storedT ) ->
                                                                let
                                                                    ( changedJ, joined0 ) =
                                                                        Mono.joinAnnotationsChanged actualType storedT

                                                                    -- Report only: positions where the body's type and the stored type disagree.
                                                                    censusCells =
                                                                        if s1.env.lss.report then
                                                                            case specKey of
                                                                                Mono.Global jcHome jcName ->
                                                                                    Mono.joinCollisionCells
                                                                                        (LssInfer.declaredArityOf (TOpt.Global jcHome jcName) 8 s1)
                                                                                        actualType
                                                                                        storedT

                                                                                _ ->
                                                                                    []

                                                                        else
                                                                            []

                                                                    -- At a licensed kernel alias, a ⊤ the join made over a stored set takes the set back.
                                                                    ( joinedR, recoveredN ) =
                                                                        if licensedKernelAliasNode node s1 then
                                                                            Mono.recoverStoredSets joined0 storedT

                                                                        else
                                                                            ( joined0, 0 )

                                                                    -- The global's own spine, stamped again on the joined type; `changedJ` stays as it was.
                                                                    joined1 =
                                                                        case specKey of
                                                                            Mono.Global sgHome sgName ->
                                                                                case Translate.stampSelfSpine (TOpt.Global sgHome sgName) joinedR s1 of
                                                                                    ( stamped, _ ) ->
                                                                                        stamped

                                                                            _ ->
                                                                                -- An accessor has no global of its own to stamp.
                                                                                joinedR

                                                                    censusCells1 =
                                                                        List.repeat recoveredN "rsTop|recovered" ++ censusCells
                                                                in
                                                                Just ( changedJ, joined1, censusCells1 )

                                                            Nothing ->
                                                                Just ( False, actualType, [] )

                                                    else
                                                        Nothing

                                                registry2 =
                                                    if nodeSupportsRetranslation node then
                                                        case completionJoin of
                                                            Just ( _, joined, _ ) ->
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

                                                s3 =
                                                    case completionJoin of
                                                        Just ( True, _, _ ) ->
                                                            Engine.bumpCompletionJoin s2

                                                        Just ( False, _, _ ) ->
                                                            Engine.bumpCompletionJoinNoop s2

                                                        Nothing ->
                                                            s2

                                                s4 =
                                                    case completionJoin of
                                                        Just ( _, _, cells ) ->
                                                            List.foldl Engine.bumpArgFlowCensus s3 cells

                                                        Nothing ->
                                                            s3
                                            in
                                            Ok (finishNode specId monoNode s4)


{-| Returns, for each lambda key, the smallest member id that the sets in
`monoType` carry for a qualified instance of that lambda, according to the
member table's `lambdaQualified`; empty with LSS off. It becomes
`ItemAux.demandQualified`, which the μ-tie in `Engine.lambdaInstanceMemberId`
consults.
-}
demandQualifiedFor : Mono.MonoType -> S -> Dict.Dict Int Int
demandQualifiedFor monoType s =
    if not s.env.lss.enabled then
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


{-| Returns the node `specializeNode` gives, translating again against the same
store for as long as a recorded read-back of an erased type variable has been
bound since (`staleResidualRead`).

The store only gains bindings during an item, so the next pass reads them. It
has to happen here, with the store in hand, because a later flush round would
start from a fresh store and repeat the same read. When pass `attempt` reaches
`maxSaturationPasses` with a stale read left, the result is an `EngineBug`.
Specs enqueued by an earlier pass remain, and pruning drops any that nothing
references.

-}
specializeNodeSaturating : Int -> Name -> ModuleName.Canonical -> TOpt.Node TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
specializeNodeSaturating attempt name home node monoType s =
    case specializeNode name home node monoType s of
        ( monoNode, s1 ) ->
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


{-| The most translation passes `specializeNodeSaturating` makes for one item.
-}
maxSaturationPasses : Int
maxSaturationPasses =
    5


{-| Returns the node for one spec of the global `name` of `home` at `monoType`,
by the kind of the global's node.

A definition is translated by `defineFrom`; a constructor, enum or box by
`Translate`, with its tag from `CtorTag.effective`, a box being a one-field
constructor with tag 0. A cycle is translated for the member the spec demands,
which is the current global rather than `name`. An incoming port demanded at a
function type, and every outgoing port, go to `Translate.specializePort`; an
incoming port demanded at any other type is its decoder, translated as a
definition. A link is followed to its target. A kernel, or a link to a global
with no node, becomes a `MonoExtern`, and an effect manager a
`MonoManagerLeaf` named after its module.

-}
specializeNode : Name -> ModuleName.Canonical -> TOpt.Node TypeIds.MVarId -> Mono.MonoType -> S -> ( Mono.MonoNode, S )
specializeNode name home node monoType s =
    case node of
        TOpt.Define expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.TrackedDefine _ expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.Kernel _ _ ->
            ( Mono.MonoExtern monoType, s )

        TOpt.Ctor index arity canType ->
            Translate.specializeCtorViaScheme name (CtorTag.effective home name index) arity canType monoType s

        TOpt.Enum index canType ->
            Translate.enumNode (CtorTag.effective home name index) canType monoType s

        TOpt.Box canType ->
            -- A box is a one-field constructor with tag 0.
            Translate.specializeCtorViaScheme name 0 1 canType monoType s

        TOpt.Link linkedGlobal ->
            case HashMap.get TOpt.globalHash (==) linkedGlobal s.env.toptNodes of
                Nothing ->
                    ( Mono.MonoExtern monoType, s )

                Just linkedNode ->
                    case linkedGlobal of
                        TOpt.Global linkedHome linkedName ->
                            specializeNode linkedName linkedHome linkedNode monoType s

        TOpt.Manager _ ->
            case home of
                ModuleName.Canonical _ modName ->
                    ( Mono.MonoManagerLeaf (Name.toElmString modName) monoType, s )

        TOpt.Cycle _ valueDefs funcDefs _ ->
            -- `name` is the cycle's own; the member demanded is the current global.
            let
                reqName =
                    case s.currentGlobal of
                        Just (Mono.Global _ n) ->
                            n

                        _ ->
                            name
            in
            Translate.specializeCycle reqName valueDefs funcDefs monoType s

        TOpt.PortIncoming expr _ meta ->
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    Translate.specializePort True expr meta.tipe monoType s

                _ ->
                    -- Demanded at the decoder's type: the decoder, translated as a definition.
                    defineFrom (TOpt.typeOf expr) expr monoType s

        TOpt.PortOutgoing expr _ meta ->
            Translate.specializePort False expr meta.tipe monoType s


{-| Returns the node of the global `name` of `home` and its annotation variable
ids (`nodeAnnotationIds`), memoized per global in `nodeResolution`, which
`resetItem` keeps, so every spec of a global after the first reuses them.
-}
resolveGlobalNode : ModuleName.Canonical -> Name -> S -> ( Engine.NodeResolution, S )
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
                            nodeAnnotationIds s.env.toptNodes 8 n

                        Nothing ->
                            EverySet.empty

                resolution =
                    { node = node, annIds = annIds }
            in
            ( resolution, { s | nodeResolution = Dict.insert gkey resolution s.nodeResolution } )


{-| Returns the ids of the type variables in the types of `node`: its
annotation, the types of every member of a cycle, and those of a link's target,
following at most `depth` links. A kernel or effect manager has none.
-}
nodeAnnotationIds : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> Int -> TOpt.Node TypeIds.MVarId -> EverySet.EverySet Int Int
nodeAnnotationIds toptNodes depth node =
    let
        fromCans ts =
            EverySet.fromList identity (List.map Id.toComparable (List.foldl (\t acc -> KernelAbi.freeVarIds t acc) [] ts))

        defType def =
            case def of
                TOpt.Def _ _ _ t ->
                    t

                TOpt.TailDef _ _ _ _ t _ ->
                    t
    in
    case node of
        TOpt.Define _ _ meta ->
            fromCans [ meta.tipe ]

        TOpt.TrackedDefine _ _ _ meta ->
            fromCans [ meta.tipe ]

        TOpt.Cycle _ valueDefs funcDefs _ ->
            fromCans (List.map (\( _, vexpr ) -> TOpt.typeOf vexpr) valueDefs ++ List.map defType funcDefs)

        TOpt.PortIncoming _ _ meta ->
            fromCans [ meta.tipe ]

        TOpt.PortOutgoing _ _ meta ->
            fromCans [ meta.tipe ]

        TOpt.Ctor _ _ canType ->
            fromCans [ canType ]

        TOpt.Enum _ canType ->
            fromCans [ canType ]

        TOpt.Box canType ->
            fromCans [ canType ]

        TOpt.Link target ->
            if depth <= 0 then
                EverySet.empty

            else
                case HashMap.get TOpt.globalHash (==) target toptNodes of
                    Just targetNode ->
                        nodeAnnotationIds toptNodes (depth - 1) targetNode

                    Nothing ->
                        EverySet.empty

        _ ->
            EverySet.empty


{-| Returns a `MonoDefine` of `expr` at `demand`. The definition's annotation is
unified with `demand` first (`Translate.demandUnifyRoot`), so the body is read
at that instantiation, and the node's type is the translated body's type.
-}
defineFrom : Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> S -> ( Mono.MonoNode, S )
defineFrom annCanType expr demand s =
    case Translate.demandUnifyRoot annCanType demand expr s of
        s1 ->
            case Translate.translate expr s1 of
                ( monoExpr, s2 ) ->
                    ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s2 )


{-| Tells whether a spec of `node` can be translated again with a joined stored
type: true for definitions, cycles, ports and links, false for constructors,
enums, boxes, kernels and effect managers.

A node of the second kind has no body that reads lambda sets, and its registry
type is left as it was stored. A link is accepted whatever its target; links lead
to cycles and, for an effect module's `command` and `subscription`, to its
manager.

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
            True

        _ ->
            False


{-| Tells whether `nd` is a kernel alias, a definition whose whole body is a
kernel reference (following links), whose kernel has a `TypeFaithful` fact that
`KernelSetFacts.licenseApplies` accepts at the reference's type.

At such a node `processItem` lets a stored set replace a ⊤ that the join
produced. The alias adds no members of its own, and the license says the kernel
makes no function values beyond those its type passes through, so the stored
set is taken as complete.

-}
licensedKernelAliasNode : TOpt.Node TypeIds.MVarId -> S -> Bool
licensedKernelAliasNode nd s =
    let
        licensed kPrefix kHome kName kMeta =
            case KernelSetFacts.factFor kPrefix kHome kName of
                Just (KernelSetFacts.TypeFaithful license) ->
                    KernelSetFacts.licenseApplies (Engine.isScalarVar s) license kMeta.tipe

                _ ->
                    False
    in
    case nd of
        TOpt.Define (TOpt.VarKernel _ kPrefix kHome kName kMeta) _ _ ->
            licensed kPrefix kHome kName kMeta

        TOpt.TrackedDefine _ (TOpt.VarKernel _ kPrefix kHome kName kMeta) _ _ ->
            licensed kPrefix kHome kName kMeta

        TOpt.Link target ->
            case HashMap.get TOpt.globalHash (==) target s.env.toptNodes of
                Just nd2 ->
                    licensedKernelAliasNode nd2 s

                Nothing ->
                    False

        _ ->
            False


{-| Returns the state with `monoNode` stored as the node of `specId` and the
item closed: the spec is no longer in progress, no global or spec is current,
and `qLog` is empty. First the item's read-backs are replayed
(`Store.rezonkSettled`) and its constraints checked against the store
(`Store.qShadowCensus`); both only add to the census, and both must run now,
since the next item starts with a fresh store.
-}
finishNode : Mono.SpecId -> Mono.MonoNode -> S -> S
finishNode specId monoNode s =
    let
        -- Before `itemAux` is changed below: the replay reads its logs.
        sSettled =
            Store.rezonkSettled s

        sQ =
            Store.qShadowCensus sSettled

        aux =
            sQ.itemAux
    in
    { sQ
        | nodes = arraySetGrowing specId (Just monoNode) sQ.nodes
        , inProgress = BitSet.removeGrowing specId sQ.inProgress
        , currentGlobal = Nothing

        -- So a member minted between items is not qualified by this spec.
        , itemAux = { aux | currentSpecId = Nothing, qLog = [] }
    }


{-| Tells whether a read-back recorded in this item, which gave an erased type
variable, has since been bound, so that translating again against the same
store would read it bound.

A read recorded by Point counts when the variable is now bound (`varResolvedNow`)
and is still equivalent to the item memo's Point for its MVarId. A Point not
equivalent to the memo's, such as one loaded for a single call site, does not
count. A read recorded by MVarId counts when the memo now holds a bound Point
for it.

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


{-| Tells whether the read of `var` counts as stale, as `staleResidualRead`
describes for reads recorded by Point.
-}
staleVarRead : S -> Vars.Variable -> Bool
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


{-| Tells whether `var` is bound in `store`: to a structure, an alias, or the
`number` super type, flexible or rigid.
-}
varResolvedNow : IO.State -> Vars.Variable -> Bool
varResolvedNow store var =
    let
        ( _, desc ) =
            UF.get var store
    in
    case desc.content of
        Vars.Structure _ ->
            True

        Vars.Alias _ _ _ _ ->
            True

        Vars.FlexSuper Vars.Number _ ->
            True

        Vars.RigidSuper Vars.Number _ ->
            True

        _ ->
            False


{-| Tells whether a node has been stored for `specId`.
-}
nodeAlreadyDone : Mono.SpecId -> S -> Bool
nodeAlreadyDone specId s =
    case Array.get specId s.nodes of
        Just (Just _) ->
            True

        _ ->
            False



-- ====== ASSEMBLY ======


{-| Returns the unpruned graph of the drained state, with `mainSpecId` as its
main and `flagsDecoderSpecId` as its flags decoder.

The call edges of a node are the specs it references, and a node that
references a kernel of the `Debug` module is marked as having effects. Every
referenced spec, and main, is marked as used as a value. The registry keeps only
its reverse mapping, and `ctorShapes` is left empty. `lssMemberKinds`, member id
to full key, is filled only with `lss.report`. `lssBlockedMembers` are the ids
the μ-tie reused.

-}
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
        , lssMemberKinds =
            if s.env.lss.report then
                Dict.foldl (\key mid acc -> Dict.insert mid key acc) Dict.empty s.lssMemberTable.byKey

            else
                Dict.empty
        , lssBlockedMembers = s.lssMemberTable.muTied
        }


{-| Returns what each member that is not a lambda stands for, by member id, from
its key's prefix and its recorded source: a `g|` member is a global, or a
constructor when `globalOrigin` finds one behind it; `c|` a constructor; `k|` a
kernel; `a|` an accessor, named by the rest of its key; `p|` a partial
application. Lambda (`l|`) members, and members whose recorded source is not of
the kind the prefix calls for, are left out.
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
                        Just (Engine.SourceKernel ( prefix, home, name )) ->
                            Dict.insert mid (Mono.OriginKernel prefix home name) acc

                        _ ->
                            acc

                "a|" ->
                    Dict.insert mid (Mono.OriginAccessor (String.dropLeft 2 key)) acc

                "p|" ->
                    case Dict.get mid table.sources of
                        Just (Engine.SourcePap g supplied) ->
                            Dict.insert mid (Mono.OriginPap (toptToMono g) supplied) acc

                        _ ->
                            acc

                _ ->
                    acc
        )
        Dict.empty
        table.byKey


{-| Returns `OriginCtor` for a global that is a constructor or box, through
links and aliases (`ctorBackedGlobal`), and `OriginGlobal` otherwise.

A constructor can be a `g|` member, not only a `c|` one: a reference to it as
an ordinary global, such as `Just`, is minted under `g|`.

-}
globalOrigin : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.Global -> Mono.MemberOrigin
globalOrigin toptNodes g =
    if ctorBackedGlobal toptNodes 8 g then
        Mono.OriginCtor (toptToMono g)

    else
        Mono.OriginGlobal (toptToMono g)


{-| Tells whether `g` is a constructor or box node, following links, and
definitions whose whole body is a reference to another global or a box, for at
most `fuel` steps.
-}
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


{-| Returns the same global as a `Mono.Global`.
-}
toptToMono : TOpt.Global -> Mono.Global
toptToMono (TOpt.Global h n) =
    Mono.Global h n


{-| Returns `rawGraph` pruned and closed by `Prune.pruneUnreachableSpecs`, given
the drained state's type-variable supply and super table.
-}
pruneGraph : S -> Mono.MonoGraph -> Mono.MonoGraph
pruneGraph s rawGraph =
    Prune.pruneUnreachableSpecs
        (State.initMVarEnv s.nextMVarId s.superTable)
        s.env.globalTypeEnv
        rawGraph



-- ====== CALL EDGES AND EFFECTS ======


{-| Returns `acc` with one expression's contribution, as the step of a fold over
every expression of a body: a global reference adds its spec to the edges, and a
reference to a kernel of the `Debug` module sets the effects flag.
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


{-| Returns the specs a node's body references, with repeats, and whether it
references a kernel of the `Debug` module. A node without a body references
nothing.
-}
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


{-| Returns the same global as a `Mono.Global`.
-}
toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


{-| Returns `arr` with `value` at `index`, padded with `Nothing` first when the
array is too short.
-}
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

module Compiler.Monomorphize.EntryPrep exposing
    ( Assigned, assign, assignIn
    , flagsDecoderName, findEntryPointId, findNodeAnnotationType
    )

{-| Monomorphization starts from a typed graph in which every type variable,
lambda and arrow has a program-wide id, and from a decoder for the entry
point's flags. This module produces both, once, so that the pre-mono passes and
whichever monomorphization engine is selected all start from the same graph.

`assign` turns a `TOpt.GlobalGraph Name` into an `Assigned` value in two steps.
First it adds the _flags decoder_: a synthetic `Define` named
`flagsDecoderName` (`main$flagsDecoder`) in the entry's home module, holding the
decoder for the flags of a `Platform.Program flags model msg` entry. An entry of
any other type gets none. Then it runs `AssignMVarIds.assignIds`, whose module
docstring describes the ids. The decoder node is built with names and so is
inserted before the ids are assigned.

The entry is the `Define` or `TrackedDefine` with that name in the root
module when one is given (`assignIn`); otherwise, by its name alone, the first
such node in any module, in the graph's key order. `findEntryPointId` and
`findNodeAnnotationType` look up the entry and a node's annotation in the
graph after assignment.

@docs Assigned, assign, assignIn
@docs flagsDecoderName, findEntryPointId, findNodeAnnotationType

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.EcoEnvironment as EcoEnvironment
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.Names as Names
import Compiler.LocalOpt.Typed.Port as Port
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Reporting.Annotation as A
import Data.Map as DMap


{-| A typed graph after id assignment, with the id-supply state that produced
it and the global of the flags decoder (`Nothing` when the entry is not a
`Program` or no entry was found).

Every `MVarId`, source-lambda id and `ArrowId` already exists on `graph`, so a
pass that creates or copies a node must take new ids from `mvarState` (through
`Compiler.GlobalOpt.PreMono.Fresh`) rather than reuse one.

-}
type alias Assigned =
    { graph : TOpt.GlobalGraph TypeIds.MVarId
    , flagsGlobal : Maybe TOpt.Global
    , mvarState : AssignMVarIds.GlobalMVarState
    , entryHome : Maybe ModuleName.Canonical
    }


{-| Returns the `Assigned` form of `graph`: the flags decoder for the entry
named `entryPointName` is inserted, then ids are assigned.

The pair is passed to `AssignMVarIds.assignIds` as its `useSolverRoots` and
`censusOn` arguments.

-}
assign : ( Bool, Bool ) -> Name -> TOpt.GlobalGraph Name -> Assigned
assign flags entryPointName graph =
    assignIn flags Nothing entryPointName graph


{-| `assign`, with the entry looked up in module `entryHome` only when that is
given. The module is kept in the result as `entryHome`, so that the
monomorphizer enters the same definition.
-}
assignIn : ( Bool, Bool ) -> Maybe ModuleName.Canonical -> Name -> TOpt.GlobalGraph Name -> Assigned
assignIn ( useSolverRoots, censusOn ) entryHome entryPointName graph =
    let
        ( graphWithFlags, maybeFlagsGlobal ) =
            insertFlagsDecoderNode entryHome entryPointName graph

        ( assignedGraph, mvarState ) =
            AssignMVarIds.assignIds useSolverRoots censusOn graphWithFlags
    in
    { graph = assignedGraph
    , flagsGlobal = maybeFlagsGlobal
    , mvarState = mvarState
    , entryHome = entryHome
    }


{-| The name of the synthetic flags-decoder global. The `$` cannot appear in an
Elm identifier, so the name cannot collide with a user definition.
-}
flagsDecoderName : Name
flagsDecoderName =
    "main$flagsDecoder"


{-| Returns the graph with a flags-decoder node added, and that node's global,
when the entry named `entryPointName` is a `Program`; otherwise the graph
unchanged and `Nothing`.

The entry is the first `Define` or `TrackedDefine` with that name, in any
module. Its type is deep-dealiased; when the result is
`Platform.Program flags model msg`, a `Define` of type `Json.Decode.Decoder flags`
is inserted under `flagsDecoderName` in the entry's home module. Its body is a
reference to `System.environmentDecoder` when `EcoEnvironment.isEnvironmentFlags`
holds for the type as written, and otherwise the decoder `Port.toFlagsDecoder`
builds for `flags`.

-}
insertFlagsDecoderNode : Maybe ModuleName.Canonical -> Name -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Maybe TOpt.Global )
insertFlagsDecoderNode entryHome entryPointName ((TOpt.GlobalGraph nodes fields annots roots varSupers) as graph) =
    let
        entryMeta : Maybe ( ModuleName.Canonical, Can.Type Name )
        entryMeta =
            findEntryPointId entryHome entryPointName nodes
                |> Maybe.map (\( TOpt.Global home _, tipe ) -> ( home, tipe ))
    in
    case entryMeta of
        Nothing ->
            ( graph, Nothing )

        Just ( home, tipe ) ->
            insertDecoderFor home tipe graph


{-| Adds the flags decoder for an entry in `home` of type `tipe`, when that
type is a `Program`.
-}
insertDecoderFor : ModuleName.Canonical -> Can.Type Name -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Maybe TOpt.Global )
insertDecoderFor home tipe ((TOpt.GlobalGraph nodes fields annots roots varSupers) as graph) =
    case Type.deepDealias tipe of
        Can.TType hm nm [ flagsType, _, _ ] ->
            if hm == ModuleName.platform && nm == Name.program then
                let
                    decoderCanType : Can.Type Name
                    decoderCanType =
                        Can.TType ModuleName.jsonDecode "Decoder" [ flagsType ]

                    -- An eco/system Environment cannot come from JSON.
                    ( deps, _, decoderExpr ) =
                        if EcoEnvironment.isEnvironmentFlags tipe then
                            Names.run
                                (Names.registerGlobal A.zero
                                    EcoEnvironment.systemHome
                                    EcoEnvironment.environmentDecoderName
                                    decoderCanType
                                    Nothing
                                )

                        else
                            Names.run (Port.toFlagsDecoder flagsType)

                    flagsGlobal : TOpt.Global
                    flagsGlobal =
                        TOpt.Global home flagsDecoderName

                    node : TOpt.Node Name
                    node =
                        TOpt.Define decoderExpr deps { tipe = decoderCanType, tvar = Nothing }
                in
                ( TOpt.GlobalGraph (DMap.insert TOpt.toComparableGlobal flagsGlobal node nodes) fields annots roots varSupers
                , Just flagsGlobal
                )

            else
                ( graph, Nothing )

        _ ->
            ( graph, Nothing )


{-| Returns the global and annotation type of the entry: the `Define` or
`TrackedDefine` named `entryPointName` in module `entryHome` when that is given,
otherwise the first one with that name in any module, or `Nothing`.
-}
findEntryPointId : Maybe ModuleName.Canonical -> Name -> DMap.Dict String TOpt.Global (TOpt.Node id) -> Maybe ( TOpt.Global, Can.Type id )
findEntryPointId entryHome entryPointName nodes =
    case entryHome of
        Just home ->
            let
                global =
                    TOpt.Global home entryPointName
            in
            Maybe.map (Tuple.pair global) (findNodeAnnotationType global nodes)

        Nothing ->
            DMap.foldl
                (\global node acc ->
                    case acc of
                        Just _ ->
                            acc

                        Nothing ->
                            case ( global, node ) of
                                ( TOpt.Global _ name, TOpt.Define _ _ meta ) ->
                                    if name == entryPointName then
                                        Just ( global, meta.tipe )

                                    else
                                        Nothing

                                ( TOpt.Global _ name, TOpt.TrackedDefine _ _ _ meta ) ->
                                    if name == entryPointName then
                                        Just ( global, meta.tipe )

                                    else
                                        Nothing

                                _ ->
                                    Nothing
                )
                Nothing
                nodes


{-| Returns the annotation type of the node at `global` when it is a `Define` or
`TrackedDefine`, and `Nothing` for any other node or a missing one.
-}
findNodeAnnotationType : TOpt.Global -> DMap.Dict String TOpt.Global (TOpt.Node id) -> Maybe (Can.Type id)
findNodeAnnotationType global nodes =
    case DMap.get TOpt.toComparableGlobal global nodes of
        Just (TOpt.Define _ _ meta) ->
            Just meta.tipe

        Just (TOpt.TrackedDefine _ _ _ meta) ->
            Just meta.tipe

        _ ->
            Nothing

module Compiler.PreMono.EntryPrep exposing
    ( Assigned, FlagsDecoder, assignIn
    , flagsDecoderName, findEntryPointId, findNodeAnnotationType
    )

{-| Monomorphization starts from a typed graph in which every type variable,
lambda and arrow has a program-wide id, and from a decoder for the entry
point's flags. This module produces both, once, so that the pre-mono passes and
whichever monomorphization engine is selected all start from the same graph.

`assignIn` turns a `TOpt.GlobalGraph Name` into an `Assigned` value in two
steps. First it adds the _flags decoder_: a synthetic `Define` named
`flagsDecoderName` (`main$flagsDecoder`) in the entry's home module, holding the
decoder for the flags of a `Platform.Program flags model msg` entry. An entry of
any other type gets none. Then it runs `AssignMVarIds.assignIds`, whose module
docstring describes the ids. The decoder node is built with names and so is
inserted before the ids are assigned.

The entry is the `Define` or `TrackedDefine` with that name in the given root
module. `findEntryPointId` and `findNodeAnnotationType` look up the entry and a
node's annotation in the graph after assignment.

@docs Assigned, FlagsDecoder, assignIn
@docs flagsDecoderName, findEntryPointId, findNodeAnnotationType

-}

import Compiler.Canonicalize.Effects as Effects
import Compiler.Core.Annotation as A
import Compiler.Core.Name as Name exposing (Name)
import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Canonical.Alias as Type
import Compiler.IR.Runtime.EcoEnvironment as EcoEnvironment
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.LocalOpt.Typed.Names as Names
import Compiler.LocalOpt.Typed.Port as Port
import Compiler.PreMono.AssignMVarIds as AssignMVarIds
import Data.Map as DMap
import System.Crash exposing (crash)


{-| A typed graph after id assignment, with the id-supply state that produced
it, the flags decoder (`Nothing` when the entry is not a `Program` or no entry
was found), and the root module the entry is looked up in.

Every `MVarId`, source-lambda id and `ArrowId` already exists on `graph`, so a
pass that creates or copies a node must take new ids from `mvarState` (through
`Compiler.PreMono.Fresh`) rather than reuse one.

-}
type alias Assigned =
    { graph : TOpt.GlobalGraph TypeIds.MVarId
    , flags : Maybe FlagsDecoder
    , mvarState : AssignMVarIds.GlobalMVarState
    , entryHome : ModuleName.Canonical
    }


{-| The synthetic flags-decoder global and its annotation type after id
assignment. The pre-mono passes keep a `Define`'s annotation, so the type is
the one the node has in every later graph. `fromJson` is False when the decoder
ignores the host's JSON, as eco/system's `Environment` decoder does.
-}
type alias FlagsDecoder =
    { global : TOpt.Global
    , tipe : Can.Type TypeIds.MVarId
    , fromJson : Bool
    }


{-| Returns the `Assigned` form of `graph`: the flags decoder for the entry
named `entryPointName` in module `entryHome` is inserted, then ids are
assigned. The module is kept in the result as `entryHome`, so that the
monomorphizer enters the same definition.

The pair is passed to `AssignMVarIds.assignIds` as its `useSolverRoots` and
`censusOn` arguments.

-}
assignIn : ( Bool, Bool ) -> ModuleName.Canonical -> Name -> TOpt.GlobalGraph Name -> Assigned
assignIn ( useSolverRoots, censusOn ) entryHome entryPointName graph =
    let
        ( graphWithFlags, maybeFlags ) =
            insertFlagsDecoderNode entryHome entryPointName graph

        ( assignedGraph, mvarState ) =
            AssignMVarIds.assignIds useSolverRoots censusOn graphWithFlags

        (TOpt.GlobalGraph assignedNodes _ _ _ _) =
            assignedGraph
    in
    { graph = assignedGraph
    , flags =
        Maybe.andThen
            (\( global, fromJson ) ->
                Maybe.map (\tipe -> FlagsDecoder global tipe fromJson) (findNodeAnnotationType global assignedNodes)
            )
            maybeFlags
    , mvarState = mvarState
    , entryHome = entryHome
    }


{-| The name of the synthetic flags-decoder global. The `$` cannot appear in an
Elm identifier, so the name cannot collide with a user definition.
-}
flagsDecoderName : Name
flagsDecoderName =
    "main$flagsDecoder"


{-| Returns the graph with a flags-decoder node added, and that node's global
with whether the decoder reads the host's JSON, when the entry named
`entryPointName` is a `Program`; otherwise the graph unchanged and `Nothing`.

The entry is the `Define` or `TrackedDefine` with that name in `entryHome`. Its
type is deep-dealiased; when the result is
`Platform.Program flags model msg`, a `Define` of type `Json.Decode.Decoder flags`
is inserted under `flagsDecoderName` in the entry's home module. Its body is a
reference to `System.environmentDecoder` when `EcoEnvironment.isEnvironmentFlags`
holds for the type as written, and otherwise the decoder `Port.toFlagsDecoder`
builds for `flags` as `Effects.checkPayload` validates it. Flags it rejects
crash the compiler: `Compiler.LocalOpt.Typed.Module` has already reported them.

-}
insertFlagsDecoderNode : ModuleName.Canonical -> Name -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Maybe ( TOpt.Global, Bool ) )
insertFlagsDecoderNode entryHome entryPointName ((TOpt.GlobalGraph nodes _ _ _ _) as graph) =
    case findEntryPointId entryHome entryPointName nodes of
        Nothing ->
            ( graph, Nothing )

        Just ( _, tipe ) ->
            insertDecoderFor entryHome tipe graph


{-| Adds the flags decoder for an entry in `home` of type `tipe`, when that
type is a `Program`, as `insertFlagsDecoderNode` describes.
-}
insertDecoderFor : ModuleName.Canonical -> Can.Type Name -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Maybe ( TOpt.Global, Bool ) )
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
                            case Effects.checkPayload flagsType of
                                Ok payload ->
                                    Names.run (Port.toFlagsDecoder payload)

                                Err _ ->
                                    crash "Compiler.PreMono.EntryPrep.insertDecoderFor: the entry's flags passed Effects.checkPayload in LocalOpt.Typed.Module"

                    flagsGlobal : TOpt.Global
                    flagsGlobal =
                        TOpt.Global home flagsDecoderName

                    node : TOpt.Node Name
                    node =
                        TOpt.Define decoderExpr deps { tipe = decoderCanType, tvar = Nothing }
                in
                ( TOpt.GlobalGraph (DMap.insert TOpt.toComparableGlobal flagsGlobal node nodes) fields annots roots varSupers
                , Just ( flagsGlobal, not (EcoEnvironment.isEnvironmentFlags tipe) )
                )

            else
                ( graph, Nothing )

        _ ->
            ( graph, Nothing )


{-| Returns the global and annotation type of the entry: the `Define` or
`TrackedDefine` named `entryPointName` in module `entryHome`, or `Nothing`.
-}
findEntryPointId : ModuleName.Canonical -> Name -> DMap.Dict String TOpt.Global (TOpt.Node id) -> Maybe ( TOpt.Global, Can.Type id )
findEntryPointId entryHome entryPointName nodes =
    let
        global =
            TOpt.Global entryHome entryPointName
    in
    Maybe.map (Tuple.pair global) (findNodeAnnotationType global nodes)


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

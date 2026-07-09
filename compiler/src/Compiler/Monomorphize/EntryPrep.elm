module Compiler.Monomorphize.EntryPrep exposing
    ( flagsDecoderName
    , insertFlagsDecoderNode
    , findEntryPointId
    , findNodeAnnotationType
    )

{-| Engine-agnostic monomorphization input preparation, shared by the two
monomorphizer drivers (`Compiler.Monomorphize.Monomorphize` and
`Compiler.MonoSolver.Monomorphize`).

Extracted verbatim from the original driver so both engines see byte-identical
entry-point discovery and flags-decoder synthesis. Nothing here depends on
either engine's type machinery.

@docs flagsDecoderName, insertFlagsDecoderNode, findEntryPointId, findNodeAnnotationType

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.Names as Names
import Compiler.LocalOpt.Typed.Port as Port
import Data.Map as DMap
import System.TypeCheck.IO as IO


{-| The synthetic Global holding the root program's flags decoder. The `$`
is sanitized by the MLIR backend (Names.sanitizeName) and cannot collide
with a user-written Elm identifier.
-}
flagsDecoderName : Name
flagsDecoderName =
    "main$flagsDecoder"


{-| Synthesize the flags-decoder node for the entry point (Phase 5).

Walks the pre-MVarId graph for the entry's `Define`/`TrackedDefine` node;
when its (dealiased) annotation is `Program flags model msg`, builds the
payload decoder with the same `Port.toFlagsDecoder` the JS pipeline uses
and inserts it as a plain `Define` node under `flagsDecoderName` in the
entry's home module. Non-Program entries (test value mains) get none.

-}
insertFlagsDecoderNode : Name -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Maybe TOpt.Global )
insertFlagsDecoderNode entryPointName ((TOpt.GlobalGraph nodes fields annots roots varSupers) as graph) =
    let
        entryMeta : Maybe ( IO.Canonical, Can.Type Name )
        entryMeta =
            DMap.foldl TOpt.compareGlobal
                (\global node acc ->
                    case acc of
                        Just _ ->
                            acc

                        Nothing ->
                            case ( global, node ) of
                                ( TOpt.Global home name, TOpt.Define _ _ meta ) ->
                                    if name == entryPointName then
                                        Just ( home, meta.tipe )

                                    else
                                        Nothing

                                ( TOpt.Global home name, TOpt.TrackedDefine _ _ _ meta ) ->
                                    if name == entryPointName then
                                        Just ( home, meta.tipe )

                                    else
                                        Nothing

                                _ ->
                                    Nothing
                )
                Nothing
                nodes
    in
    case entryMeta of
        Nothing ->
            ( graph, Nothing )

        Just ( home, tipe ) ->
            case Type.deepDealias tipe of
                Can.TType hm nm [ flagsType, _, _ ] ->
                    if hm == ModuleName.platform && nm == Name.program then
                        let
                            ( deps, _, decoderExpr ) =
                                Names.run (Port.toFlagsDecoder flagsType)

                            decoderCanType : Can.Type Name
                            decoderCanType =
                                Can.TType ModuleName.jsonDecode "Decoder" [ flagsType ]

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


{-| Find an entry point by name in the ID-rewritten global graph.
-}
findEntryPointId : Name -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> Maybe ( TOpt.Global, Can.Type TypeIds.MVarId )
findEntryPointId entryPointName nodes =
    DMap.foldl TOpt.compareGlobal
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


{-| Look up a node's annotation type (Define/TrackedDefine meta.tipe).
-}
findNodeAnnotationType : TOpt.Global -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> Maybe (Can.Type TypeIds.MVarId)
findNodeAnnotationType global nodes =
    case DMap.get TOpt.toComparableGlobal global nodes of
        Just (TOpt.Define _ _ meta) ->
            Just meta.tipe

        Just (TOpt.TrackedDefine _ _ _ meta) ->
            Just meta.tipe

        _ ->
            Nothing

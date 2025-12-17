module Compiler.Generate.Mode exposing
    ( Mode(..), isDebug
    , ShortFieldNames, shortenFieldNames
    )

{-| Code generation modes for the Elm compiler.

This module defines the different compilation modes (development, production, debug)
and handles production-mode optimizations like field name shortening. The mode affects
code generation strategies, including whether to include debug metadata, preserve
human-readable names, and apply space-saving transformations.


# Mode

@docs Mode, isDebug


# Field Name Optimization

@docs ShortFieldNames, shortenFieldNames

-}

import Compiler.AST.Optimized as Opt
import Compiler.Data.Name as Name
import Compiler.Elm.Compiler.Type.Extract as Extract
import Compiler.Generate.JavaScript.Name as JsName
import Data.Map as Dict exposing (Dict)
import Utils.Main as Utils



-- MODE


type Mode
    = Dev (Maybe Extract.Types)
    | Prod ShortFieldNames


isDebug : Mode -> Bool
isDebug mode =
    case mode of
        Dev (Just _) ->
            True

        Dev Nothing ->
            False

        Prod _ ->
            False



-- SHORTEN FIELD NAMES


type alias ShortFieldNames =
    Dict String Name.Name JsName.Name


shortenFieldNames : Opt.GlobalGraph -> ShortFieldNames
shortenFieldNames (Opt.GlobalGraph _ frequencies) =
    Dict.foldr compare addToBuckets Dict.empty frequencies |> Dict.foldr compare (\_ -> addToShortNames) Dict.empty


addToBuckets : Name.Name -> Int -> Dict Int Int (List Name.Name) -> Dict Int Int (List Name.Name)
addToBuckets field frequency buckets =
    Utils.mapInsertWith identity (++) frequency [ field ] buckets


addToShortNames : List Name.Name -> ShortFieldNames -> ShortFieldNames
addToShortNames fields shortNames =
    List.foldl addField shortNames fields


addField : Name.Name -> ShortFieldNames -> ShortFieldNames
addField field shortNames =
    let
        rename : JsName.Name
        rename =
            JsName.fromInt (Dict.size shortNames)
    in
    Dict.insert identity field rename shortNames

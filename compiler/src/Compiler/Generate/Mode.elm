module Compiler.Generate.Mode exposing
    ( Mode(..), isDebug
    , ShortFieldNames, shortenFieldNames
    )

{-| A build is either for development or for production, and code generation
needs to know which; this module is that choice.

A `Mode` is `Dev` or `Prod`. A development build may also carry the type
information the debugger needs, and `isDebug` asks whether it does. A
production build carries a table of short field names: every record field name
in the program, paired with a short JavaScript property name to write in its
place, so that the output is smaller.

That table is built by `shortenFieldNames` from how often each field name is
used. The most used names get the shortest replacements.


# Mode

@docs Mode, isDebug


# Field Name Optimization

@docs ShortFieldNames, shortenFieldNames

-}

import Compiler.AST.Optimized as Opt
import Compiler.Data.Name as Name
import Compiler.Elm.Compiler.Type.Extract as Extract
import Compiler.Generate.JavaScript.Name as JsName
import Dict exposing (Dict)
import Utils.Main as Utils



-- ====== MODE ======


{-| The kind of build being generated.

`Dev` carries the debugger's type information when the build includes the
debugger, and `Nothing` otherwise. There is no separate debug mode: a debug
build is `Dev` with `Just` types.

`Prod` carries the short field names to use in place of record field names.

-}
type Mode
    = Dev (Maybe Extract.Types)
    | Prod ShortFieldNames


{-| Returns `True` exactly when `mode` is `Dev` carrying the debugger's type
information.
-}
isDebug : Mode -> Bool
isDebug mode =
    case mode of
        Dev (Just _) ->
            True

        Dev Nothing ->
            False

        Prod _ ->
            False



-- ====== SHORTEN FIELD NAMES ======


{-| A table from record field names to the short JavaScript names that replace
them in a production build.
-}
type alias ShortFieldNames =
    Dict Name.Name JsName.Name


{-| Returns a short name for every field name counted in the graph's field
usage table.

Names are given out as `JsName.fromInt 0`, `1`, `2` and so on, to fields in
order of descending use count, so the most used fields get the shortest names.
Fields with the same count are taken in ascending order of name.

-}
shortenFieldNames : Opt.GlobalGraph -> ShortFieldNames
shortenFieldNames (Opt.GlobalGraph _ frequencies) =
    Dict.foldr addToBuckets Dict.empty frequencies |> Dict.foldr (\_ -> addToShortNames) Dict.empty


{-| Adds `field` to the list of fields used `frequency` times, at the front.
-}
addToBuckets : Name.Name -> Int -> Dict Int (List Name.Name) -> Dict Int (List Name.Name)
addToBuckets field frequency buckets =
    Utils.dictInsertWith (++) frequency [ field ] buckets


{-| Gives each of `fields`, in list order, the next unused short name.
-}
addToShortNames : List Name.Name -> ShortFieldNames -> ShortFieldNames
addToShortNames fields shortNames =
    List.foldl addField shortNames fields


{-| Gives `field` the next short name, the one numbered by how many names the
table already holds.
-}
addField : Name.Name -> ShortFieldNames -> ShortFieldNames
addField field shortNames =
    let
        rename : JsName.Name
        rename =
            JsName.fromInt (Dict.size shortNames)
    in
    Dict.insert field rename shortNames

module Compiler.GlobalOpt.ListCombinators exposing (Combinator(..), recognize, report)

{-| Finds the specializations in a monomorphized program that are instances of
elm/core's own `List` functions, so that list-specific code generation and the
list census can single them out.

A _combinator_ here is one of a fixed set of definitions in elm/core's `List`
module; `Combinator` lists them, including three that module does not expose
(`foldrHelper`, `takeFast`, `takeReverse`).

Recognition is by origin, not by body. The specialization registry records,
for each SpecId it has an entry for, the global the specialization was created
from (see `Compiler.AST.Monomorphized`'s `SpecializationRegistry`). A spec is
recognized when that global is a combinator's name in module `List` of package `elm/core`.
A function of the same name in any other module is never recognized, and
inlining or rewriting a spec's body does not change whether it is.

Recognition only reads the graph. `recognize` gives the mapping and `report`
renders a one-line count of it.

@docs Combinator, recognize, report

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)


{-| An elm/core `List` definition that recognition can identify, one
constructor per definition.

Each constructor stands for the definition whose name `combinatorName` gives.
`FoldrHelper`, `TakeFast` and `TakeReverse` are internal helpers of elm/core's
`List` module rather than exposed functions.

-}
type Combinator
    = Foldl
    | Foldr
    | FoldrHelper
    | Map
    | IndexedMap
    | Filter
    | FilterMap
    | ConcatMap
    | Concat
    | Append
    | Reverse
    | Intersperse
    | Partition
    | Unzip
    | Repeat
    | Range
    | Any
    | All
    | Member
    | Length
    | Sum
    | Product
    | Maximum
    | Minimum
    | Take
    | TakeFast
    | TakeReverse
    | Drop
    | Sort
    | SortBy
    | SortWith


{-| Returns the name of the elm/core `List` definition a combinator stands for,
as recognition matches it and as `report` prints it.
-}
combinatorName : Combinator -> String
combinatorName c =
    case c of
        Foldl ->
            "foldl"

        Foldr ->
            "foldr"

        FoldrHelper ->
            "foldrHelper"

        Map ->
            "map"

        IndexedMap ->
            "indexedMap"

        Filter ->
            "filter"

        FilterMap ->
            "filterMap"

        ConcatMap ->
            "concatMap"

        Concat ->
            "concat"

        Append ->
            "append"

        Reverse ->
            "reverse"

        Intersperse ->
            "intersperse"

        Partition ->
            "partition"

        Unzip ->
            "unzip"

        Repeat ->
            "repeat"

        Range ->
            "range"

        Any ->
            "any"

        All ->
            "all"

        Member ->
            "member"

        Length ->
            "length"

        Sum ->
            "sum"

        Product ->
            "product"

        Maximum ->
            "maximum"

        Minimum ->
            "minimum"

        Take ->
            "take"

        TakeFast ->
            "takeFast"

        TakeReverse ->
            "takeReverse"

        Drop ->
            "drop"

        Sort ->
            "sort"

        SortBy ->
            "sortBy"

        SortWith ->
            "sortWith"


{-| The lookup from an elm/core `List` definition name to its combinator. A
name absent from it is not recognized.
-}
table : Dict Name.Name Combinator
table =
    Dict.fromList
        [ ( "foldl", Foldl )
        , ( "foldr", Foldr )
        , ( "foldrHelper", FoldrHelper )
        , ( "map", Map )
        , ( "indexedMap", IndexedMap )
        , ( "filter", Filter )
        , ( "filterMap", FilterMap )
        , ( "concatMap", ConcatMap )
        , ( "concat", Concat )
        , ( "append", Append )
        , ( "reverse", Reverse )
        , ( "intersperse", Intersperse )
        , ( "partition", Partition )
        , ( "unzip", Unzip )
        , ( "repeat", Repeat )
        , ( "range", Range )
        , ( "any", Any )
        , ( "all", All )
        , ( "member", Member )
        , ( "length", Length )
        , ( "sum", Sum )
        , ( "product", Product )
        , ( "maximum", Maximum )
        , ( "minimum", Minimum )
        , ( "take", Take )
        , ( "takeFast", TakeFast )
        , ( "takeReverse", TakeReverse )
        , ( "drop", Drop )
        , ( "sort", Sort )
        , ( "sortBy", SortBy )
        , ( "sortWith", SortWith )
        ]


{-| Returns, keyed by SpecId, the combinator of every specialization in `graph`
whose registry origin is a combinator's definition in elm/core's `List` module.

A spec whose origin is in any other module, an accessor, or a registry slot
holding `Nothing` is left out, so a user-defined function named `map` is never
recognized.

-}
recognize : Mono.MonoGraph -> Dict Int Combinator
recognize (Mono.MonoGraph { registry }) =
    Array.toIndexedList registry.reverseMapping
        |> List.foldl
            (\( specId, entry ) acc ->
                case entry of
                    Just ( Mono.Global (ModuleName.Canonical pkg "List") name, _ ) ->
                        if pkg == Pkg.core then
                            case Dict.get name table of
                                Just comb ->
                                    Dict.insert specId comb acc

                                Nothing ->
                                    acc

                        else
                            acc

                    _ ->
                        acc
            )
            Dict.empty


{-| Returns a one-line census of the recognized specializations in `graph`.

The line starts `[list-combinators] total=N`, where N is the number recognized,
followed by `name=count` for each combinator with at least one spec, largest
count first and ties in alphabetical order.

-}
report : Mono.MonoGraph -> String
report graph =
    let
        counts : Dict String Int
        counts =
            recognize graph
                |> Dict.foldl
                    (\_ comb acc ->
                        let
                            key =
                                combinatorName comb
                        in
                        Dict.insert key (1 + Maybe.withDefault 0 (Dict.get key acc)) acc
                    )
                    Dict.empty

        total =
            Dict.foldl (\_ n acc -> n + acc) 0 counts

        rendered =
            Dict.toList counts
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                |> String.join " "
    in
    "[list-combinators] total=" ++ String.fromInt total ++ " " ++ rendered

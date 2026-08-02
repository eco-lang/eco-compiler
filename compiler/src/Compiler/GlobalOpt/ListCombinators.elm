module Compiler.GlobalOpt.ListCombinators exposing (Combinator(..), combinatorName, recognize, report)

{-| elm/core List combinator recognition (chunked-list plan L1.1,
plans/chunked-list-representation.md §6 / §9.2 Tier B).

Recognition is by specialization ORIGIN: a spec whose registry entry
resolves to `Global ModuleName.list <name>` with `<name>` in the combinator
table below. Provenance is the same channel Names.elm mangles into symbols,
so recognition is immune to body inlining, LSS keying, and renaming.

L1.1 scope: recognition + census only (`ECO_LIST_REPORT=1`), output-only —
never affects artifacts. The census gate is agreement with the L0 static
census (plan §11.a): foldl 1,939 specs, foldrHelper 815, takeFast 17, ...
on the self-compile workload. L1.3 consumes `recognize` at MLIR generation
to substitute chunk loop templates (behind `list.chunks`).

@docs Combinator, combinatorName, recognize, report

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| The recognized elm/core List combinators, grouped by the template class
that will handle them in L1.3 (plan §6):

  - forward TCO loops (already `scf.while` via TailRec; cursor handling is
    generic): Foldl, Any, All, Member, Length, Sum, Product, Maximum,
    Minimum, TakeReverse, Drop
  - backward walks (chunk backward-cursor in L1.3): Foldr, FoldrHelper,
    TakeFast
  - producers (dense-chunk output in L1.3): Map, IndexedMap, Filter,
    FilterMap, ConcatMap, Concat, Append, Reverse, Intersperse, Partition,
    Unzip, Repeat, Range
  - sort family (Tier A / kernel-owned in L2): Sort, SortBy, SortWith

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


{-| Render a combinator name for reports (matches the elm/core definition
name it was recognized from).
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


{-| Definition-name → combinator table. Keys are the elm/core `List` module
definition names, including the non-exported helpers the L0 census showed
carry the traffic (`foldrHelper`, `takeFast`, `takeReverse`).
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


{-| Map every SpecId whose registry origin is an elm/core `List` combinator
to its combinator. Specs whose origin is any other module — including
user-defined functions named `map` — are never recognized.
-}
recognize : Mono.MonoGraph -> Dict Int Combinator
recognize (Mono.MonoGraph { registry }) =
    Array.toIndexedList registry.reverseMapping
        |> List.foldl
            (\( specId, entry ) acc ->
                case entry of
                    Just ( Mono.Global (IO.Canonical pkg "List") name, _ ) ->
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


{-| One-line census: recognized spec counts per combinator plus the total,
greppable as `[list-combinators]`. Compared against the L0 static census
(plan §11.a) as the L1.1 gate.
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

module Data.Set exposing
    ( EverySet
    , empty, insert, remove
    , isEmpty, member, size
    , union, diff
    , toList, fromList
    , foldr, filter
    )

{-| A set implementation for values of any type, backed by association lists.

This module provides sets that can contain any type of value, not just comparable types.
You provide a function to convert values to comparable representations for internal storage.
The implementation is based on Data.Map, which uses association lists internally.
Initial implementation from `Gizra/elm-all-set/1.0.1`.


# Sets

@docs EverySet


# Build

@docs empty, insert, remove


# Query

@docs isEmpty, member, size


# Combine

@docs union, diff


# Lists

@docs toList, fromList


# Transform

@docs foldr, filter

-}

import Data.Map as Dict exposing (Dict)


{-| Represents a set of unique values. So `(Set Int)` is a set of integers and
`(Set String)` is a set of strings.
-}
type EverySet c a
    = EverySet (Dict c a ())


{-| Create an empty set.
-}
empty : EverySet c a
empty =
    EverySet Dict.empty


{-| Insert a value into a set.
-}
insert : (a -> comparable) -> a -> EverySet comparable a -> EverySet comparable a
insert toComparable k (EverySet d) =
    Dict.insert toComparable k () d |> EverySet


{-| Remove a value from a set. If the value is not found, no changes are made.
-}
remove : (a -> comparable) -> a -> EverySet comparable a -> EverySet comparable a
remove toComparable k (EverySet d) =
    Dict.remove toComparable k d |> EverySet


{-| Determine if a set is empty.
-}
isEmpty : EverySet c a -> Bool
isEmpty (EverySet d) =
    Dict.isEmpty d


{-| Determine if a value is in a set.
-}
member : (a -> comparable) -> a -> EverySet comparable a -> Bool
member toComparable k (EverySet d) =
    Dict.member toComparable k d


{-| Determine the number of elements in a set.
-}
size : EverySet c a -> Int
size (EverySet d) =
    Dict.size d


{-| Get the union of two sets. Keep all values.
-}
union : EverySet comparable a -> EverySet comparable a -> EverySet comparable a
union (EverySet d1) (EverySet d2) =
    Dict.union d1 d2 |> EverySet


{-| Get the difference between the first set and the second. Keeps values
that do not appear in the second set.
-}
diff : EverySet comparable a -> EverySet comparable a -> EverySet comparable a
diff (EverySet d1) (EverySet d2) =
    Dict.diff d1 d2 |> EverySet


{-| Convert a set into a list, sorted from lowest to highest.
-}
toList : (a -> a -> Order) -> EverySet c a -> List a
toList keyComparison (EverySet d) =
    Dict.keys keyComparison d


{-| Convert a list into a set, removing any duplicates.
-}
fromList : (a -> comparable) -> List a -> EverySet comparable a
fromList toComparable xs =
    List.foldl (insert toComparable) empty xs


{-| Fold over the values in a set, in order from highest to lowest.
-}
foldr : (a -> a -> Order) -> (a -> b -> b) -> b -> EverySet c a -> b
foldr keyComparison f b (EverySet d) =
    Dict.foldr keyComparison (\k _ result -> f k result) b d


{-| Create a new set consisting only of elements which satisfy a predicate.
-}
filter : (a -> Bool) -> EverySet comparable a -> EverySet comparable a
filter p (EverySet d) =
    Dict.filter (\k _ -> p k) d |> EverySet

module Data.Set exposing
    ( EverySet
    , empty, insert, insertKeyed
    , isEmpty, member, memberKeyed, size
    , union, diff
    , toList, fromList
    , foldr, filter
    )

{-| Elm's core `Set` accepts only `comparable` elements, which rules out custom
types and records; this module is a set whose elements can be of any type.

It is a `Data.Map` dictionary whose keys are the elements and whose values are
all `()`, so it works exactly as `Data.Map` describes: the caller passes a key
projection, a function `a -> comparable`, wherever an element is added or
looked up, and two elements are the same element exactly when their
projections are equal. The set's first type parameter is the comparable type
that the projection produces. Every call on one set must pass the same
projection; nothing records or checks it.

Elements are ordered by their projections: `toList` goes lowest first and
`foldr` highest first. Both take an `a -> a -> Order` function and ignore it.

`memberKeyed` and `insertKeyed` take an element's projection that the caller
has already computed, so that testing for an element and then inserting it
projects it once rather than twice.


# Sets

@docs EverySet


# Build

@docs empty, insert, insertKeyed


# Query

@docs isEmpty, member, memberKeyed, size


# Combine

@docs union, diff


# Lists

@docs toList, fromList


# Transform

@docs foldr, filter

-}

import Data.Map as Dict exposing (Dict)


{-| A set of elements of type `a`, where `c` is the comparable type that the
key projection produces.

It holds at most one element for each key it is filed under, which is the
element's projection as long as every `insertKeyed` key is one. A set is made
with `empty` or `fromList`. Adding an element whose projection is already
present replaces the stored element, except in `union`, which keeps the first
set's element.

-}
type EverySet c a
    = EverySet (Dict c a ())


{-| The set with no elements.
-}
empty : EverySet c a
empty =
    EverySet Dict.empty


{-| Inserts `k` under its projection, replacing any element already stored
there.
-}
insert : (a -> comparable) -> a -> EverySet comparable a -> EverySet comparable a
insert toComparable k (EverySet d) =
    Dict.insert toComparable k () d |> EverySet


{-| Returns whether the set has no elements.
-}
isEmpty : EverySet c a -> Bool
isEmpty (EverySet d) =
    Dict.isEmpty d


{-| Returns whether an element with the same projection as `k` is in the set.
-}
member : (a -> comparable) -> a -> EverySet comparable a -> Bool
member toComparable k (EverySet d) =
    Dict.member toComparable k d


{-| Returns whether an element is stored under `comparableKey`, a projection
the caller has already computed.

Paired with `insertKeyed`, this lets a caller test for an element and then
insert it while projecting it only once, which matters when the projection is
costly to compute.

-}
memberKeyed : comparable -> EverySet comparable a -> Bool
memberKeyed comparableKey (EverySet d) =
    Dict.memberKeyed comparableKey d


{-| Inserts `k` under `comparableKey`, a projection the caller has already
computed, replacing any element stored there.

Nothing checks that `comparableKey` is the projection of `k`. If it is not, a
later `member` test for `k` looks under its projection, not where `k` was
stored.

-}
insertKeyed : comparable -> a -> EverySet comparable a -> EverySet comparable a
insertKeyed comparableKey k (EverySet d) =
    Dict.insertKeyed comparableKey k () d |> EverySet


{-| Returns the number of elements.
-}
size : EverySet c a -> Int
size (EverySet d) =
    Dict.size d


{-| Returns every element of both sets. Where both hold an element with the
same projection, the first set's element is kept.
-}
union : EverySet comparable a -> EverySet comparable a -> EverySet comparable a
union (EverySet d1) (EverySet d2) =
    Dict.union d1 d2 |> EverySet


{-| Returns the elements of the first set whose projection is not in the
second.
-}
diff : EverySet comparable a -> EverySet comparable a -> EverySet comparable a
diff (EverySet d1) (EverySet d2) =
    Dict.diff d1 d2 |> EverySet


{-| Returns the elements in ascending order of their projections. The ordering
function is ignored.
-}
toList : (a -> a -> Order) -> EverySet c a -> List a
toList keyComparison (EverySet d) =
    Dict.keys keyComparison d


{-| Creates a set from a list, inserting from left to right. Where two elements
have the same projection, the later one is kept.
-}
fromList : (a -> comparable) -> List a -> EverySet comparable a
fromList toComparable xs =
    List.foldl (insert toComparable) empty xs


{-| Folds `f` over the elements in descending order of their projections,
highest first. The ordering function is ignored.
-}
foldr : (a -> a -> Order) -> (a -> b -> b) -> b -> EverySet c a -> b
foldr keyComparison f b (EverySet d) =
    Dict.foldr keyComparison (\k _ result -> f k result) b d


{-| Keeps only the elements for which `p` returns `True`.
-}
filter : (a -> Bool) -> EverySet comparable a -> EverySet comparable a
filter p (EverySet d) =
    Dict.filter (\k _ -> p k) d |> EverySet

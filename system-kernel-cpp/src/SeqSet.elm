module SeqSet exposing
    ( SeqSet
    , empty, singleton, insert, remove
    , isEmpty, member, size, unorderedEquals
    , union, intersect, diff
    , toList, fromList
    , map, foldl, foldr, filter, partition
    )

{-| A set of unique values.


# Sets

@docs SeqSet


# Build

@docs empty, singleton, insert, remove


# Query

@docs isEmpty, member, size, unorderedEquals


# Combine

@docs union, intersect, diff


# Lists

@docs toList, fromList


# Transform

@docs map, foldl, foldr, filter, partition


-}

import SeqDict as Dict exposing (SeqDict)


{-| Represents a set of unique values. So `(Set Int)` is a set of integers and
`(Set String)` is a set of strings.
-}
type SeqSet a
    = SeqSet_elm_builtin (SeqDict a Bool)


{-| Create an empty set.
-}
empty : SeqSet a
empty =
    SeqSet_elm_builtin Dict.empty


{-| Create a set with one value.
-}
singleton : a -> SeqSet a
singleton k =
    SeqSet_elm_builtin (Dict.singleton k True)


{-| Insert a value into a set.
-}
insert : a -> SeqSet a -> SeqSet a
insert k (SeqSet_elm_builtin dict) =
    SeqSet_elm_builtin (Dict.insert k True dict)


{-| Remove a value from a set. If the value is not found, no changes are made.
-}
remove : a -> SeqSet a -> SeqSet a
remove k (SeqSet_elm_builtin dict) =
    SeqSet_elm_builtin (Dict.remove k dict)


{-| Determine if a set is empty.
-}
isEmpty : SeqSet a -> Bool
isEmpty (SeqSet_elm_builtin dict) =
    Dict.isEmpty dict


{-| Determine if a value is in a set.
-}
member : a -> SeqSet a -> Bool
member k (SeqSet_elm_builtin dict) =
    Dict.member k dict


{-| Determine the number of elements in a set.
-}
size : SeqSet a -> Int
size (SeqSet_elm_builtin dict) =
    Dict.size dict


{-| Get the union of two sets. Keep all values.
-}
union : SeqSet a -> SeqSet a -> SeqSet a
union (SeqSet_elm_builtin d1) (SeqSet_elm_builtin d2) =
    SeqSet_elm_builtin (Dict.union d1 d2)


{-| Get the intersection of two sets. Keeps values that appear in both sets.
-}
intersect : SeqSet a -> SeqSet a -> SeqSet a
intersect (SeqSet_elm_builtin d1) (SeqSet_elm_builtin d2) =
    SeqSet_elm_builtin (Dict.intersect d1 d2)


{-| Get the difference between the first set and the second. Keeps values
that do not appear in the second set.
-}
diff : SeqSet a -> SeqSet a -> SeqSet a
diff (SeqSet_elm_builtin d1) (SeqSet_elm_builtin d2) =
    SeqSet_elm_builtin (Dict.diff d1 d2)


{-| Convert a set into a list.
-}
toList : SeqSet a -> List a
toList (SeqSet_elm_builtin dict) =
    Dict.keys dict


{-| Convert a list into a set, removing any duplicates.
-}
fromList : List a -> SeqSet a
fromList xs =
    List.foldl insert empty xs


{-| Fold over the values in a set.
-}
foldl : (a -> b -> b) -> b -> SeqSet a -> b
foldl f b (SeqSet_elm_builtin dict) =
    Dict.foldl (\k _ b2 -> f k b2) b dict


{-| Fold over the values in a set.
-}
foldr : (a -> b -> b) -> b -> SeqSet a -> b
foldr f b (SeqSet_elm_builtin dict) =
    Dict.foldr (\k _ b2 -> f k b2) b dict


{-| Map a function onto a set, creating a new set with no duplicates.
-}
map : (a -> b) -> SeqSet a -> SeqSet b
map fn (SeqSet_elm_builtin dict) =
    SeqSet_elm_builtin (Dict.foldl (\k _ b2 -> Dict.insert (fn k) True b2) Dict.empty dict)


{-| Create a new set consisting only of elements which satisfy a predicate.
-}
filter : (a -> Bool) -> SeqSet a -> SeqSet a
filter p (SeqSet_elm_builtin dict) =
    SeqSet_elm_builtin (Dict.filter (\k _ -> p k) dict)


{-| Create two new sets; the first consisting of elements which satisfy a
predicate, the second consisting of elements which do not.
-}
partition : (a -> Bool) -> SeqSet a -> ( SeqSet a, SeqSet a )
partition p (SeqSet_elm_builtin dict) =
    let
        ( trues, falses ) =
            Dict.partition (\k _ -> p k) dict
    in
    ( SeqSet_elm_builtin trues, SeqSet_elm_builtin falses )


orderedEquals : SeqSet k -> SeqSet k -> Bool
orderedEquals set1 set2 =
    if size set1 == size set2 then
        toList set1 == toList set2

    else
        False


{-| Check if two sets are equal regardless what order items were inserted.
Note that this is not the same as writing `set1 == set2`. Insertion order matters when using `==`.

    set1 = SeqSet.fromList [ ( "A", 1 ), ( "B", 2 ) ]
    set2 = SeqSet.fromList [ ( "B", 2 ), ( "A", 1 ) ]

    SeqSet.unorderedEquals set1 set2 -- True
    set1 == set2 -- False

-}
unorderedEquals : SeqSet k -> SeqSet k -> Bool
unorderedEquals (SeqSet_elm_builtin dict1) (SeqSet_elm_builtin dict2) =
    Dict.unorderedEquals dict1 dict2

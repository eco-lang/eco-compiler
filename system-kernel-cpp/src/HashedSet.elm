module HashedSet exposing
    ( HashedSet
    , empty, singleton, insert, remove
    , isEmpty, member, size, unorderedEquals, find, intern
    , union, intersect, diff
    , toList, fromList
    , map, foldl, foldr, filter, partition
    )

{-| A set of [`Hashed`](Hash#Hashed) values, preserving insertion order: a `SeqSet` whose elements
carry their hash.

`find` and `intern` hand back the element stored in the set, which makes it a hash-consing table:
build each value from canonical parts, `intern` it, and keep what comes back. Equal structures then
share one object, `==` on them is a pointer comparison, and hashing a structure built from them reads
its parts' stored hashes.

    type Ty
        = TInt
        | TList (Hashed Ty)

    tList : Hashed Ty -> HashedSet Ty -> ( Hashed Ty, HashedSet Ty )
    tList elem set =
        HashedSet.intern (Hash.hashed (TList elem)) set


# Sets

@docs HashedSet


# Build

@docs empty, singleton, insert, remove


# Query

@docs isEmpty, member, size, unorderedEquals, find, intern


# Combine

@docs union, intersect, diff


# Lists

@docs toList, fromList


# Transform

@docs map, foldl, foldr, filter, partition

-}

import Hash exposing (Hashed)
import SeqDict exposing (SeqDict)


{-| A set of `Hashed a` values, in insertion order.
-}
type HashedSet a
    = HashedSet (SeqDict (Hashed a) ())


{-| An empty set.
-}
empty : HashedSet a
empty =
    HashedSet SeqDict.empty


{-| A set of one element.
-}
singleton : Hashed a -> HashedSet a
singleton x =
    HashedSet (SeqDict.singleton x ())


{-| Insert an element. An equal element already present is replaced by this one (in its place); use
`intern` to keep the stored one.
-}
insert : Hashed a -> HashedSet a -> HashedSet a
insert x (HashedSet dict) =
    HashedSet (SeqDict.insert x () dict)


{-| Remove an element. Do nothing if it is not present.
-}
remove : Hashed a -> HashedSet a -> HashedSet a
remove x (HashedSet dict) =
    HashedSet (SeqDict.remove x dict)


{-| Whether the set is empty.
-}
isEmpty : HashedSet a -> Bool
isEmpty (HashedSet dict) =
    SeqDict.isEmpty dict


{-| Whether an equal element is present.
-}
member : Hashed a -> HashedSet a -> Bool
member x (HashedSet dict) =
    SeqDict.member x dict


{-| The number of elements.
-}
size : HashedSet a -> Int
size (HashedSet dict) =
    SeqDict.size dict


{-| Whether two sets hold the same elements, in any order. `==` also compares the order.
-}
unorderedEquals : HashedSet a -> HashedSet a -> Bool
unorderedEquals (HashedSet a) (HashedSet b) =
    SeqDict.unorderedEquals a b


{-| The element stored in the set that equals `x`, if any. It may be a different object from `x`.
-}
find : Hashed a -> HashedSet a -> Maybe (Hashed a)
find x (HashedSet dict) =
    Maybe.map Tuple.first (SeqDict.lookup x dict)


{-| The element stored in the set that equals `x`, with the set unchanged; or, when there is none, `x`
itself with the set holding it. Either way the result is the one canonical copy of `x`.
-}
intern : Hashed a -> HashedSet a -> ( Hashed a, HashedSet a )
intern x ((HashedSet dict) as set) =
    case SeqDict.lookup x dict of
        Just ( stored, _ ) ->
            ( stored, set )

        Nothing ->
            ( x, HashedSet (SeqDict.insert x () dict) )


{-| The elements of both sets. Where both hold equal elements, the first set's is kept.
-}
union : HashedSet a -> HashedSet a -> HashedSet a
union (HashedSet a) (HashedSet b) =
    HashedSet (SeqDict.union a b)


{-| The elements of the first set that are in the second.
-}
intersect : HashedSet a -> HashedSet a -> HashedSet a
intersect (HashedSet a) (HashedSet b) =
    HashedSet (SeqDict.intersect a b)


{-| The elements of the first set that are not in the second.
-}
diff : HashedSet a -> HashedSet a -> HashedSet a
diff (HashedSet a) (HashedSet b) =
    HashedSet (SeqDict.diff a b)


{-| The elements, in insertion order. They are the stored `Hashed` values.
-}
toList : HashedSet a -> List (Hashed a)
toList (HashedSet dict) =
    SeqDict.keys dict


{-| A set of the elements of a list.
-}
fromList : List (Hashed a) -> HashedSet a
fromList xs =
    HashedSet (SeqDict.fromList (List.map (\x -> ( x, () )) xs))


{-| Map a function onto a set, creating a new set with no duplicates.
-}
map : (Hashed a -> Hashed b) -> HashedSet a -> HashedSet b
map f (HashedSet dict) =
    HashedSet (SeqDict.foldl (\x _ acc -> SeqDict.insert (f x) () acc) SeqDict.empty dict)


{-| Fold over the elements in insertion order.
-}
foldl : (Hashed a -> b -> b) -> b -> HashedSet a -> b
foldl f acc (HashedSet dict) =
    SeqDict.foldl (\x _ b -> f x b) acc dict


{-| Fold over the elements in reverse insertion order.
-}
foldr : (Hashed a -> b -> b) -> b -> HashedSet a -> b
foldr f acc (HashedSet dict) =
    SeqDict.foldr (\x _ b -> f x b) acc dict


{-| The elements that satisfy a test.
-}
filter : (Hashed a -> Bool) -> HashedSet a -> HashedSet a
filter p (HashedSet dict) =
    HashedSet (SeqDict.filter (\x _ -> p x) dict)


{-| Split the elements by a test: those that pass, then those that fail.
-}
partition : (Hashed a -> Bool) -> HashedSet a -> ( HashedSet a, HashedSet a )
partition p (HashedSet dict) =
    let
        ( yes, no ) =
            SeqDict.partition (\x _ -> p x) dict
    in
    ( HashedSet yes, HashedSet no )

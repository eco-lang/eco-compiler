module HashedDict exposing
    ( HashedDict
    , empty, singleton, insert, update, updateIfExists, remove
    , get, lookup, isEmpty, member, size, unorderedEquals
    , union, intersect, diff, merge
    , toList, fromList, keys, values
    , foldl, foldr, map, filter, filterMap, partition
    )

{-| A dictionary keyed by [`Hashed`](Hash#Hashed) values, preserving insertion order: a `SeqDict`
whose keys carry their hash.

A key is hashed once, when its `Hashed` is made, instead of on every operation, so a structured key
(a record, a list, a custom type) costs a walk only when it is built. A hit still compares the probe
with the stored key with `==`, which looks at the values unless the two are the same object: probe
with the stored keys (or canonical ones, from `HashedSet.intern`) and that comparison is a pointer
comparison too.

`Debug.toString` of a `HashedDict` shows its internal structure, which is not specified and may
change; print `toList` instead.


# Dictionary

@docs HashedDict


# Build

@docs empty, singleton, insert, update, updateIfExists, remove


# Query

@docs get, lookup, isEmpty, member, size, unorderedEquals


# Combine

@docs union, intersect, diff, merge


# Lists

@docs toList, fromList, keys, values


# Transform

@docs foldl, foldr, map, filter, filterMap, partition

-}

import Hash exposing (Hashed)
import SeqDict exposing (SeqDict)


{-| A dictionary from `Hashed k` keys to `v` values, in insertion order.
-}
type HashedDict k v
    = HashedDict (SeqDict (Hashed k) v)


{-| An empty dictionary.
-}
empty : HashedDict k v
empty =
    HashedDict SeqDict.empty


{-| A dictionary of one key-value pair.
-}
singleton : Hashed k -> v -> HashedDict k v
singleton key v =
    HashedDict (SeqDict.singleton key v)


{-| Insert a key-value pair. Replaces the value when the key is present.
-}
insert : Hashed k -> v -> HashedDict k v -> HashedDict k v
insert key v (HashedDict dict) =
    HashedDict (SeqDict.insert key v dict)


{-| Update the value of a key with a function of its current value, if any. `Nothing` removes it.
-}
update : Hashed k -> (Maybe v -> Maybe v) -> HashedDict k v -> HashedDict k v
update key f (HashedDict dict) =
    HashedDict (SeqDict.update key f dict)


{-| Update the value of a key that is present; do nothing otherwise.
-}
updateIfExists : Hashed k -> (v -> v) -> HashedDict k v -> HashedDict k v
updateIfExists key f (HashedDict dict) =
    HashedDict (SeqDict.updateIfExists key f dict)


{-| Remove a key. Do nothing if it is not present.
-}
remove : Hashed k -> HashedDict k v -> HashedDict k v
remove key (HashedDict dict) =
    HashedDict (SeqDict.remove key dict)


{-| The value of a key, if present.
-}
get : Hashed k -> HashedDict k v -> Maybe v
get key (HashedDict dict) =
    SeqDict.get key dict


{-| The key stored in the dictionary that equals `key`, with its value. The stored key may be a
different object from `key`: probing with it later makes the hit comparison a pointer comparison.
-}
lookup : Hashed k -> HashedDict k v -> Maybe ( Hashed k, v )
lookup key (HashedDict dict) =
    SeqDict.lookup key dict


{-| Whether the dictionary is empty.
-}
isEmpty : HashedDict k v -> Bool
isEmpty (HashedDict dict) =
    SeqDict.isEmpty dict


{-| Whether a key is present.
-}
member : Hashed k -> HashedDict k v -> Bool
member key (HashedDict dict) =
    SeqDict.member key dict


{-| The number of key-value pairs.
-}
size : HashedDict k v -> Int
size (HashedDict dict) =
    SeqDict.size dict


{-| Whether two dictionaries hold the same key-value pairs, in any order.
-}
unorderedEquals : HashedDict k v -> HashedDict k v -> Bool
unorderedEquals (HashedDict a) (HashedDict b) =
    SeqDict.unorderedEquals a b


{-| Combine two dictionaries. If there is a collision, preference is given to the first dictionary.
-}
union : HashedDict k v -> HashedDict k v -> HashedDict k v
union (HashedDict a) (HashedDict b) =
    HashedDict (SeqDict.union a b)


{-| The pairs of the first dictionary whose keys are in the second.
-}
intersect : HashedDict k v -> HashedDict k v1 -> HashedDict k v
intersect (HashedDict a) (HashedDict b) =
    HashedDict (SeqDict.intersect a b)


{-| The pairs of the first dictionary whose keys are not in the second.
-}
diff : HashedDict k v -> HashedDict k v1 -> HashedDict k v
diff (HashedDict a) (HashedDict b) =
    HashedDict (SeqDict.diff a b)


{-| Fold over two dictionaries at once, as `SeqDict.merge` does.
-}
merge :
    (Hashed k -> a -> result -> result)
    -> (Hashed k -> a -> b -> result -> result)
    -> (Hashed k -> b -> result -> result)
    -> HashedDict k a
    -> HashedDict k b
    -> result
    -> result
merge leftStep bothStep rightStep (HashedDict a) (HashedDict b) initialResult =
    SeqDict.merge leftStep bothStep rightStep a b initialResult


{-| The key-value pairs, in insertion order.
-}
toList : HashedDict k v -> List ( Hashed k, v )
toList (HashedDict dict) =
    SeqDict.toList dict


{-| Convert an association list into a dictionary, as `SeqDict.fromList` does.
-}
fromList : List ( Hashed k, v ) -> HashedDict k v
fromList pairs =
    HashedDict (SeqDict.fromList pairs)


{-| The keys, in insertion order. They are the stored `Hashed` keys.
-}
keys : HashedDict k v -> List (Hashed k)
keys (HashedDict dict) =
    SeqDict.keys dict


{-| The values, in insertion order.
-}
values : HashedDict k v -> List v
values (HashedDict dict) =
    SeqDict.values dict


{-| Fold over the pairs in insertion order.
-}
foldl : (Hashed k -> v -> b -> b) -> b -> HashedDict k v -> b
foldl f acc (HashedDict dict) =
    SeqDict.foldl f acc dict


{-| Fold over the pairs in reverse insertion order.
-}
foldr : (Hashed k -> v -> b -> b) -> b -> HashedDict k v -> b
foldr f acc (HashedDict dict) =
    SeqDict.foldr f acc dict


{-| Apply a function to every value.
-}
map : (Hashed k -> a -> b) -> HashedDict k a -> HashedDict k b
map f (HashedDict dict) =
    HashedDict (SeqDict.map f dict)


{-| Keep the pairs that satisfy a test.
-}
filter : (Hashed k -> v -> Bool) -> HashedDict k v -> HashedDict k v
filter f (HashedDict dict) =
    HashedDict (SeqDict.filter f dict)


{-| Apply a function that may drop a pair to every pair.
-}
filterMap : (Hashed k -> v -> Maybe v2) -> HashedDict k v -> HashedDict k v2
filterMap f (HashedDict dict) =
    HashedDict (SeqDict.filterMap f dict)


{-| Split the pairs by a test: those that pass, then those that fail.
-}
partition : (Hashed k -> v -> Bool) -> HashedDict k v -> ( HashedDict k v, HashedDict k v )
partition f (HashedDict dict) =
    let
        ( yes, no ) =
            SeqDict.partition f dict
    in
    ( HashedDict yes, HashedDict no )

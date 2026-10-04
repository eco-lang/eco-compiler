module Data.Map exposing
    ( Dict
    , empty, singleton, insert
    , isEmpty, member, get, size
    , keys, values, toList, fromList
    , map, foldl, foldr, filter
    , union, diff
    )

{-| Elm's core `Dict` accepts only `comparable` keys, which rules out custom
types and records; this module is a dictionary whose keys can be of any type.

The caller supplies a _key projection_: a function `k -> comparable` that turns
a key into a value core `Dict` can order. The dictionary files each entry under
the projection of its key, and keeps the original key with the value so that
it can hand the key back. The dictionary's first type parameter is the
comparable type the projection produces.

Three facts follow from that.

Two keys are the same key exactly when their projections are equal. A
projection that gives two different keys the same value makes them collide,
and the later insert replaces the earlier one.

Entries are ordered by their projected keys: `keys`, `values`, `toList` and
`foldl` go lowest first, `foldr` highest first. That is neither the order of
insertion nor the order of any `k -> k -> Order` function: all five take such a
function and ignore it.

Nothing records which projection a dictionary was built with. Every call on
one dictionary must pass the same projection; a different one files and looks
up entries under different keys, and no error is reported.

`memberKeyed` and `insertKeyed` take a key that the caller has already
projected, so that testing for a key and then inserting it projects the key
once rather than twice.


# Dictionaries

@docs Dict


# Build

@docs empty, singleton, insert


# Query

@docs isEmpty, member, get, size


# Lists

@docs keys, values, toList, fromList


# Transform

@docs map, foldl, foldr, filter


# Combine

@docs union, diff

-}

import Dict


{-| A dictionary from keys of type `k` to values of type `v`, where `c` is the
comparable type that the key projection produces.

It holds at most one entry for each projected key. A dictionary is made with
`empty`, `singleton` or `fromList`. Adding an entry under a projected key that
already has one replaces it, except in `union`, which keeps the first
dictionary's entry.

-}
type Dict c k v
    = D (Dict.Dict c ( k, v ))


{-| The dictionary with no entries.
-}
empty : Dict c k v
empty =
    D Dict.empty


{-| Returns the value of the entry filed under the projection of `targetKey`,
or `Nothing` if there is none.
-}
get : (k -> comparable) -> k -> Dict comparable k v -> Maybe v
get toComparable targetKey (D dict) =
    Dict.get (toComparable targetKey) dict
        |> Maybe.map Tuple.second


{-| Returns whether an entry is filed under the projection of `targetKey`.
-}
member : (k -> comparable) -> k -> Dict comparable k v -> Bool
member toComparable targetKey (D dict) =
    Dict.member (toComparable targetKey) dict


{-| Returns the number of entries, which is the number of distinct projected
keys.
-}
size : Dict c k v -> Int
size (D dict) =
    Dict.size dict


{-| Returns whether the dictionary has no entries.
-}
isEmpty : Dict c k v -> Bool
isEmpty (D dict) =
    Dict.isEmpty dict


{-| Inserts `key` and `value` under the projection of `key`.

An entry already filed there is replaced, its key as well as its value, so the
stored key becomes `key` even when it differs from the one it replaces.

-}
insert : (k -> comparable) -> k -> v -> Dict comparable k v -> Dict comparable k v
insert toComparable key value (D dict) =
    D (Dict.insert (toComparable key) ( key, value ) dict)


{-| Creates a dictionary holding one entry.
-}
singleton : (k -> comparable) -> k -> v -> Dict comparable k v
singleton toComparable key value =
    D (Dict.singleton (toComparable key) ( key, value ))



-- ====== COMBINE ======


{-| Returns every entry of both dictionaries. Where both hold an entry under the
same projected key, the first dictionary's entry is kept, key and value.
-}
union : Dict comparable k v -> Dict comparable k v -> Dict comparable k v
union (D leftDict) (D rightDict) =
    D (Dict.union leftDict rightDict)


{-| Returns the entries of the first dictionary whose projected key has no
entry in the second.
-}
diff : Dict comparable k a -> Dict comparable k b -> Dict comparable k a
diff (D leftDict) (D rightDict) =
    D (Dict.diff leftDict rightDict)



-- ====== TRANSFORM ======


{-| Returns the dictionary with each value replaced by `alter` applied to the
entry's key and value. The keys are unchanged.
-}
map : (k -> a -> b) -> Dict c k a -> Dict c k b
map alter (D dict) =
    D (Dict.map (\_ ( key, value ) -> ( key, alter key value )) dict)


{-| Folds `func` over the entries in ascending order of their projected keys,
lowest first. The ordering function is ignored.
-}
foldl : (k -> v -> b -> b) -> b -> Dict c k v -> b
foldl func initialResult (D dict) =
    Dict.foldl (\_ ( key, value ) result -> func key value result) initialResult dict


{-| Folds `func` over the entries in descending order of their projected keys,
highest first. The ordering function is ignored.
-}
foldr : (k -> v -> b -> b) -> b -> Dict c k v -> b
foldr func initialResult (D dict) =
    Dict.foldr (\_ ( key, value ) result -> func key value result) initialResult dict


{-| Keeps only the entries for which `isGood`, given the entry's key and value,
returns `True`.
-}
filter : (k -> v -> Bool) -> Dict comparable k v -> Dict comparable k v
filter isGood (D dict) =
    D (Dict.filter (\_ ( key, value ) -> isGood key value) dict)



-- ====== LISTS ======


{-| Returns the stored keys in ascending order of their projections. The
ordering function is ignored.
-}
keys : Dict c k v -> List k
keys (D dict) =
    Dict.values dict
        |> List.map Tuple.first


{-| Returns the values in ascending order of their entries' projected keys. The
ordering function is ignored.
-}
values : Dict c k v -> List v
values (D dict) =
    Dict.values dict
        |> List.map Tuple.second


{-| Returns the entries as key-value pairs in ascending order of their projected
keys. The ordering function is ignored.
-}
toList : Dict c k v -> List ( k, v )
toList (D dict) =
    Dict.values dict


{-| Creates a dictionary from key-value pairs, inserting them from left to
right. Where two pairs have the same projected key, the later pair is kept, key
and value.
-}
fromList : (k -> comparable) -> List ( k, v ) -> Dict comparable k v
fromList toComparable =
    List.foldl (\( key, value ) -> Dict.insert (toComparable key) ( key, value )) Dict.empty
        >> D

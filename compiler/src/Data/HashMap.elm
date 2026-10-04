module Data.HashMap exposing
    ( HashMap
    , empty, insert, get, getBy, member, remove
    , getHashed, insertNew
    , size, isEmpty
    , foldl, map, toList, values, fromList
    )

{-| A dictionary for keys that are costly to turn into a comparable value.

`Data.Map` files each entry under a comparable value it derives from the key
with the caller's key projection, and its `get` and `insert` apply that
projection to the key they are given. For a key whose comparable form has to
be built, rather than read off the key, that build is repeated at every call.
This module asks for two other functions instead, passed at every keyed
operation: `hash`, which gives an `Int`, and `eq`, which decides whether two
keys are the same key. No comparable form of the key is built.

The hash only chooses a bucket. Entries whose keys hash alike share a bucket,
and `eq` decides between them, so a hash that gives many keys the same value
costs time but never gives a wrong answer. Among what the map relies on are
that keys equal under `eq` have equal hashes, and that every call on one map
passes the same `hash` and `eq`. The map does not store either function and
nothing checks this: a different pair on the same map can treat as one key two
keys that the first pair kept apart, or miss a key that the first pair stored.

Iteration (`foldl`, `toList`, `values`) is in insertion order. An entry's
place in that order is fixed when its key is inserted while absent; replacing
the value of a key that is present leaves the stored key and its place
unchanged, and a key that is removed and inserted again goes last. This is not
the comparable-key order in which `Data.Map` iterates. Each entry carries a
sequence number, taken from a counter that advances for every new key, and
every iteration sorts all the entries on it.

`getHashed` and `insertNew` take a hash the caller has already computed, so
that a lookup that misses followed by an insert of the same key hashes it once.

@docs HashMap
@docs empty, insert, get, getBy, member, remove
@docs getHashed, insertNew
@docs size, isEmpty
@docs foldl, map, toList, values, fromList

-}

import Dict


{-| A map from keys of type `k` to values of type `v`, in which keys are told
apart by the `hash` and `eq` the caller passes to each keyed operation.

A map is made with `empty` or `fromList`. It holds at most one entry for each
key, as long as every call passes the same `hash` and `eq`, keys equal under
`eq` have equal hashes, and `insertNew` is given only absent keys, each with
its own hash. It iterates in insertion order.

-}
type HashMap k v
    = HashMap Int Int (Dict.Dict Int (List ( Int, k, v )))


{-| The map with no entries.
-}
empty : HashMap k v
empty =
    HashMap 0 0 Dict.empty


{-| Returns the value stored under `key`, as `get` does, but takes the hash
`h` of `key` instead of a hash function.

`h` must be what the map's `hash` gives for `key`; any other value looks in the
wrong bucket.

-}
getHashed : Int -> (k -> k -> Bool) -> k -> HashMap k v -> Maybe v
getHashed h eq key (HashMap _ _ buckets) =
    case Dict.get h buckets of
        Nothing ->
            Nothing

        Just bucket ->
            scanBucketBy eq key bucket


{-| Inserts `value` under `key`, where `h` is the hash of `key`, without
checking whether `key` is already present. It is for a key that the caller has
just looked up with `getHashed h` and not found.

If `key` is in fact present, the map ends up with two entries for it: `size`
counts both, iteration visits both, lookups return the newer value, and
`remove` drops both while `size` falls by one.

-}
insertNew : Int -> k -> v -> HashMap k v -> HashMap k v
insertNew h key value (HashMap count nextSeq buckets) =
    HashMap (count + 1)
        (nextSeq + 1)
        (Dict.insert h (( nextSeq, key, value ) :: Maybe.withDefault [] (Dict.get h buckets)) buckets)


{-| Returns the value stored under `key`, or `Nothing` if no stored key is
equal to it under `eq`.
-}
get : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Maybe v
get hash eq key m =
    getBy hash eq key m


{-| Returns the value stored under the key that `probe` matches, where `probe`
need not be of the key type.

`hash` is applied to `probe`, and `eq probe storedKey` decides the match. A
probe and the stored key it should find must hash equal, under this `hash` and
under the `hash` the map's keys were inserted with, and must match under `eq`.

This lets a caller look up a key without first building a value of the key
type. Where the stored keys carry data computed from the rest of the key, the
probe does not have to have that data computed for it.

-}
getBy : (q -> Int) -> (q -> k -> Bool) -> q -> HashMap k v -> Maybe v
getBy hash eq probe (HashMap _ _ buckets) =
    case Dict.get (hash probe) buckets of
        Nothing ->
            Nothing

        Just bucket ->
            scanBucketBy eq probe bucket


{-| Returns the value of the first entry in `bucket` whose key `eq probe`
accepts, or `Nothing` if there is none.
-}
scanBucketBy : (q -> k -> Bool) -> q -> List ( Int, k, v ) -> Maybe v
scanBucketBy eq probe bucket =
    case bucket of
        [] ->
            Nothing

        ( _, k, v ) :: rest ->
            if eq probe k then
                Just v

            else
                scanBucketBy eq probe rest


{-| Reports whether a key equal to `key` under `eq` is stored.
-}
member : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Bool
member hash eq key (HashMap _ _ buckets) =
    case Dict.get (hash key) buckets of
        Nothing ->
            False

        Just bucket ->
            bucketMember eq key bucket


{-| Reports whether any entry in `bucket` has a key equal to `key` under `eq`.
-}
bucketMember : (k -> k -> Bool) -> k -> List ( Int, k, v ) -> Bool
bucketMember eq key bucket =
    case bucket of
        [] ->
            False

        ( _, k, _ ) :: rest ->
            eq key k || bucketMember eq key rest


{-| Inserts `value` under `key`. If a key equal to `key` under `eq` is already
stored, only its value is replaced: the stored key, and its place in iteration
order, stay as they were.
-}
insert : (k -> Int) -> (k -> k -> Bool) -> k -> v -> HashMap k v -> HashMap k v
insert hash eq key value (HashMap count nextSeq buckets) =
    let
        h =
            hash key

        bucket =
            Maybe.withDefault [] (Dict.get h buckets)
    in
    if bucketMember eq key bucket then
        HashMap count nextSeq (Dict.insert h (replaceInBucket eq key value bucket) buckets)

    else
        -- Prepending is safe for iteration, which sorts on the sequence number.
        HashMap (count + 1) (nextSeq + 1) (Dict.insert h (( nextSeq, key, value ) :: bucket) buckets)


{-| Returns `bucket` with the value of the first entry whose key equals `key`
under `eq` replaced by `value`, keeping that entry's stored key and sequence
number. A bucket with no such entry comes back unchanged.

It returns the bucket alone rather than also reporting whether it found a
match, which would take a pair at every step; `insert` asks `bucketMember`
first instead, at the cost of scanning the bucket twice.

-}
replaceInBucket : (k -> k -> Bool) -> k -> v -> List ( Int, k, v ) -> List ( Int, k, v )
replaceInBucket eq key value bucket =
    case bucket of
        [] ->
            []

        (( entrySeq, k, _ ) as entry) :: rest ->
            if eq key k then
                ( entrySeq, k, value ) :: rest

            else
                entry :: replaceInBucket eq key value rest


{-| Removes the entry whose key is equal to `key` under `eq`, and returns the
map unchanged if there is none.
-}
remove : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> HashMap k v
remove hash eq key (HashMap count nextSeq buckets) =
    let
        h =
            hash key
    in
    case Dict.get h buckets of
        Nothing ->
            HashMap count nextSeq buckets

        Just bucket ->
            -- Checked first, so that an absent key does not rebuild the bucket.
            if not (List.any (\( _, k, _ ) -> eq key k) bucket) then
                HashMap count nextSeq buckets

            else
                let
                    kept =
                        List.filter (\( _, k, _ ) -> not (eq key k)) bucket
                in
                HashMap (count - 1)
                    nextSeq
                    (if List.isEmpty kept then
                        Dict.remove h buckets

                     else
                        Dict.insert h kept buckets
                    )


{-| Returns the number of entries.
-}
size : HashMap k v -> Int
size (HashMap count _ _) =
    count


{-| Reports whether the map has no entries.
-}
isEmpty : HashMap k v -> Bool
isEmpty (HashMap count _ _) =
    count == 0


{-| Returns every entry with its sequence number, in insertion order, by
gathering the entries of all the buckets and sorting them on the sequence
number.

`foldl`, `toList` and `values` all read the map through this. It hands them the
entries as they are stored, so `foldl` and `values` build no `( k, v )` pair.

-}
orderedEntries : HashMap k v -> List ( Int, k, v )
orderedEntries (HashMap _ _ buckets) =
    Dict.foldl (\_ bucket acc -> bucket ++ acc) [] buckets
        |> List.sortBy (\( seq, _, _ ) -> seq)


{-| Folds `step` over every entry in insertion order, so the entry inserted
earliest is folded in first.
-}
foldl : (k -> v -> b -> b) -> b -> HashMap k v -> b
foldl step init m =
    List.foldl (\( _, k, v ) acc -> step k v acc) init (orderedEntries m)


{-| Applies `f` to every value, with its key. Keys and their order are
unchanged.
-}
map : (k -> a -> b) -> HashMap k a -> HashMap k b
map f (HashMap count nextSeq buckets) =
    HashMap count
        nextSeq
        (Dict.map (\_ bucket -> List.map (\( seq, k, v ) -> ( seq, k, f k v )) bucket) buckets)


{-| Returns every entry as a key and value pair, in insertion order. It builds
one pair per entry, which `foldl` and `values` do not.
-}
toList : HashMap k v -> List ( k, v )
toList m =
    List.map (\( _, k, v ) -> ( k, v )) (orderedEntries m)


{-| Returns every value, in insertion order.
-}
values : HashMap k v -> List v
values m =
    List.map (\( _, _, v ) -> v) (orderedEntries m)


{-| Builds a map from `entries`, inserting them in list order. Where two
entries have equal keys under `eq`, the later value is kept, under the earlier
key and in the earlier key's place.
-}
fromList : (k -> Int) -> (k -> k -> Bool) -> List ( k, v ) -> HashMap k v
fromList hash eq entries =
    List.foldl (\( k, v ) acc -> insert hash eq k v acc) empty entries

module Data.HashMap exposing
    ( HashMap
    , empty, insert, get, member, remove
    , size, isEmpty
    , foldl, map, toList, values, fromList
    )

{-| A dictionary for keys that carry their own structural hash.

`Data.Map` takes a key-derivation function and applies it on EVERY operation,
so a key that must be built (rather than read) is rebuilt per `get`, per
`member`, per `insert`. For `MonoType` keys that means walking the whole type
and allocating a comparable string, per lookup — the cost this structure
exists to remove (K4 of `plans/mono-comparable-key-optimization.md`).

Here the caller supplies a `hash` that is expected to be CHEAP — read out of
the key, not computed from it — plus an `eq` that decides true key equality.
Entries live in per-hash buckets, so **collisions are resolved, not assumed
away**: `hash` need only satisfy "equal keys have equal hashes", and `eq` does
the deciding. A degenerate `hash` costs performance, never correctness.

`hash` and `eq` must agree with each other and be the same at every call on a
given map, exactly as `Data.Map`'s `toComparable` must be. Passing the
annotation-sensitive pair to a map built with the annotation-erased pair (or
vice versa) silently merges distinct keys — see the flavour warning on
`Compiler.AST.Monomorphized.layoutMapGet`.

**Iteration is INSERTION-ORDERED**, not hash-ordered. Hash order is an
implementation detail that would leak into anything downstream of a fold —
and emission paths do fold these maps — so entries carry a sequence number and
iteration sorts on it. Replacing an existing key keeps its original position,
matching `Dict.insert`. This is still not the LEXICOGRAPHIC order of the string
keys these maps replace, so output that depends on traversal order does change.

@docs HashMap
@docs empty, insert, get, member, remove
@docs size, isEmpty
@docs foldl, map, toList, values, fromList

-}

import Dict


{-| A hash-bucketed map: entry count, next sequence number, and buckets by
hash. Each entry carries the sequence number it was first inserted at, which
is what makes iteration insertion-ordered.
-}
type HashMap k v
    = HashMap Int Int (Dict.Dict Int (List ( Int, k, v )))


{-| The empty map.
-}
empty : HashMap k v
empty =
    HashMap 0 0 Dict.empty


{-| Look up a key.
-}
get : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Maybe v
get hash eq key (HashMap _ _ buckets) =
    case Dict.get (hash key) buckets of
        Nothing ->
            Nothing

        Just bucket ->
            scanBucket eq key bucket


scanBucket : (k -> k -> Bool) -> k -> List ( Int, k, v ) -> Maybe v
scanBucket eq key bucket =
    case bucket of
        [] ->
            Nothing

        ( _, k, v ) :: rest ->
            if eq key k then
                Just v

            else
                scanBucket eq key rest


{-| Membership test, without materializing the value.
-}
member : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Bool
member hash eq key (HashMap _ _ buckets) =
    case Dict.get (hash key) buckets of
        Nothing ->
            False

        Just bucket ->
            bucketMember eq key bucket


bucketMember : (k -> k -> Bool) -> k -> List ( Int, k, v ) -> Bool
bucketMember eq key bucket =
    case bucket of
        [] ->
            False

        ( _, k, _ ) :: rest ->
            eq key k || bucketMember eq key rest


{-| Insert, replacing any entry whose key is equal under `eq`. The stored key
of a replaced entry is kept, matching `Dict.insert`'s behaviour of keeping the
first-inserted key.
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
        -- Replacing keeps the original sequence number, so the entry keeps its
        -- iteration position exactly as `Dict.insert` would.
        HashMap count nextSeq (Dict.insert h (replaceInBucket eq key value bucket) buckets)

    else
        -- New key: prepend. Bucket order is irrelevant — iteration sorts on the
        -- sequence number.
        HashMap (count + 1) (nextSeq + 1) (Dict.insert h (( nextSeq, key, value ) :: bucket) buckets)


{-| Deliberately returns the bucket ALONE rather than a `( bucket, added )`
pair: it is called once per insert, and a pair per recursion step was a
measurable allocation pool of its own (Run C: `Tuple2 +93.8M`). The membership
question is answered by `bucketMember` before we get here, and buckets are
almost always a single entry, so the extra scan costs nothing.
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


{-| Remove a key, if present.
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
            let
                kept =
                    List.filter (\( _, k, _ ) -> not (eq key k)) bucket
            in
            if List.length kept == List.length bucket then
                HashMap count nextSeq buckets

            else
                HashMap (count - 1)
                    nextSeq
                    (if List.isEmpty kept then
                        Dict.remove h buckets

                     else
                        Dict.insert h kept buckets
                    )


{-| Number of entries.
-}
size : HashMap k v -> Int
size (HashMap count _ _) =
    count


{-| True when there are no entries.
-}
isEmpty : HashMap k v -> Bool
isEmpty (HashMap count _ _) =
    count == 0


{-| Every entry with its sequence number, oldest insertion first. The single
ordered walk that `foldl`, `toList` and `values` all share — none of them
materialise an intermediate `( k, v )` pair, because folds over these maps run
on hot paths (a whole-map scan per pattern, in one codegen case).
-}
orderedEntries : HashMap k v -> List ( Int, k, v )
orderedEntries (HashMap _ _ buckets) =
    Dict.foldl (\_ bucket acc -> bucket ++ acc) [] buckets
        |> List.sortBy (\( seq, _, _ ) -> seq)


{-| Fold over every entry, oldest insertion first.
-}
foldl : (k -> v -> b -> b) -> b -> HashMap k v -> b
foldl step init m =
    List.foldl (\( _, k, v ) acc -> step k v acc) init (orderedEntries m)


{-| Map the values. Keys are untouched, so the buckets need no rehash.
-}
map : (k -> a -> b) -> HashMap k a -> HashMap k b
map f (HashMap count nextSeq buckets) =
    HashMap count
        nextSeq
        (Dict.map (\_ bucket -> List.map (\( seq, k, v ) -> ( seq, k, f k v )) bucket) buckets)


{-| Every entry, oldest insertion first. This is the one iteration form that
must build pairs — its result type demands them; prefer `foldl` or `values`.
-}
toList : HashMap k v -> List ( k, v )
toList m =
    List.map (\( _, k, v ) -> ( k, v )) (orderedEntries m)


{-| Every value, oldest insertion first.
-}
values : HashMap k v -> List v
values m =
    List.map (\( _, _, v ) -> v) (orderedEntries m)


{-| Build a map from entries.
-}
fromList : (k -> Int) -> (k -> k -> Bool) -> List ( k, v ) -> HashMap k v
fromList hash eq entries =
    List.foldl (\( k, v ) acc -> insert hash eq k v acc) empty entries

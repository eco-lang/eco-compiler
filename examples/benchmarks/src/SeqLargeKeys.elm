module SeqLargeKeys exposing (benchCollide, benchIntern, benchLongKey, benchLongKeyReuse, benchMultiLookup, benchPrefixKey, benchPrefixKeyFresh)

{-| `TypeKeys`' large-key workloads on eco/system's `SeqDict`, where every operation hashes the
whole key with `FNV.hash` (up to its bounds) instead of comparing it.

  - `benchLongKey` (seqdict-longkey) is dict-longkey's work: about 190-character member-key
    Strings, every lookup key freshly built, half of them missing only by the tag at the end.
    Checked in closed form, as dict-longkey is.
  - `benchLongKeyReuse` (seqdict-longkey-reuse) builds every key String once, inserts them, then
    looks up the same String objects four times over (and an absent key per present one, also
    built once). Each lookup rehashes a String that never changes, which is the case a cached
    String hash would serve. Checked in closed form.
  - `benchIntern` (seqdict-intern) is intern-cached-hash's work with a `SeqDict Ty Ty` as the
    table: the key is the type tree itself, hashed by walking it, and compared with `==`. Checked
    as the intern workloads are.
  - `benchPrefixKey` (seqdict-prefixkey) keys a `SeqDict String Int` on `size` keys of 2,000
    characters that share all but their last six (`StringCompare.prefixKey`). Every key String,
    present and absent (absent ones differ only in those last six), is built once, then looked up
    four times over: each lookup rehashes all 2,000 characters of a String that never changes, and
    each hit compares it with the stored key. Checked in closed form.
  - `benchPrefixKeyFresh` (seqdict-prefixkey-fresh) does the same lookups with a freshly built,
    equal key String each time, as a program that rebuilds its keys does; a cached hash of the
    looked-up key would be used only once.
  - `benchCollide` (seqdict-collide) inserts `size` keys of 4,200 characters that differ only after
    their first 4,100. A String hash that reads only a prefix (hash definition v2 read the first
    4,096 units) gives them all one hash and one collision list, so that every insert and lookup
    compares the key with the keys before it, each comparison reading 4,100 characters. Checked in
    closed form.
  - `benchMultiLookup` (seqdict-multi-lookup) uses each of `size` type-tree keys
    (`TypeKeys.topOfCode`, all distinct) several times in one function: `member` in three dicts
    holding every 2nd, 3rd and 5th key (`member k d1 && member k d2 && member k d3`), then a `get`
    and, on a miss, an `insert` into a fourth dict. Natively each of those operations hashes the key
    again unless the compiler merges the hashes of one key within the function
    (plans/seqdict-hash-once-per-function.md). Checked in closed form: the hit count is the number
    of indexes divisible by 30, and the fourth dict ends up with every key, its values summing to
    the triangle number.

-}

import Array
import SeqDict exposing (SeqDict)
import StringCompare
import TypeKeys exposing (Ty)


benchLongKey : Int -> Bool
benchLongKey n =
    let
        codes =
            Array.fromList (TypeKeys.drawCodes 20 n)

        codeAt j =
            Maybe.withDefault 0 (Array.get j codes)

        d =
            List.foldl (\j acc -> SeqDict.insert (TypeKeys.longKey 20 (codeAt j) j) j acc) SeqDict.empty (List.range 0 (n - 1))

        hits =
            List.foldl
                (\j acc ->
                    let
                        tag =
                            if modBy 2 j == 0 then
                                j

                            else
                                j + n
                    in
                    case SeqDict.get (TypeKeys.longKey 20 (codeAt j) tag) d of
                        Just _ ->
                            acc + 1

                        Nothing ->
                            acc
                )
                0
                (List.range 0 (n - 1))
    in
    (SeqDict.size d == n)
        && (hits == (n + 1) // 2)
        && (SeqDict.foldl (\_ v s -> s + v) 0 d == TypeKeys.triangle n)


rounds : Int
rounds =
    4


benchLongKeyReuse : Int -> Bool
benchLongKeyReuse n =
    let
        codes =
            TypeKeys.drawCodes 20 n

        -- every key String built once: present ones, and for each an absent one differing in its tag
        present =
            List.indexedMap (\j code -> TypeKeys.longKey 20 code j) codes

        absent =
            List.indexedMap (\j code -> TypeKeys.longKey 20 code (j + n)) codes

        d =
            List.foldl (\( j, key ) acc -> SeqDict.insert key j acc) SeqDict.empty (List.indexedMap Tuple.pair present)

        count keys =
            List.foldl
                (\key acc ->
                    if SeqDict.member key d then
                        acc + 1

                    else
                        acc
                )
                0
                keys

        hits =
            List.foldl (\_ acc -> acc + count present + count absent) 0 (List.range 1 rounds)
    in
    (SeqDict.size d == n)
        && (hits == rounds * n)
        && (SeqDict.foldl (\_ v s -> s + v) 0 d == TypeKeys.triangle n)


probe : Ty -> SeqDict Ty Ty -> ( Ty, Bool, SeqDict Ty Ty )
probe node d =
    case SeqDict.get node d of
        Just canon ->
            ( canon, False, d )

        Nothing ->
            ( node, True, SeqDict.insert node node d )


benchIntern : Int -> Bool
benchIntern n =
    TypeKeys.internBenchWith probe SeqDict.empty n


{-| A dict of the keys `codes` (each built on `prefix`), each with its code as the value.
-}
prefixDict : String -> List Int -> SeqDict String Int
prefixDict prefix codes =
    List.foldl (\code acc -> SeqDict.insert (StringCompare.prefixKey prefix code) code acc) SeqDict.empty codes


permutation : Int -> List Int
permutation n =
    List.map (\i -> modBy n (i * 7919 + 13)) (List.range 0 (n - 1))


countMembers : SeqDict String Int -> List String -> Int -> Int
countMembers d keys acc =
    List.foldl
        (\key c ->
            if SeqDict.member key d then
                c + 1

            else
                c
        )
        acc
        keys


benchPrefixKey : Int -> Bool
benchPrefixKey n =
    let
        prefix =
            StringCompare.prefixOf 2000

        codes =
            permutation n

        present =
            List.map (StringCompare.prefixKey prefix) codes

        absent =
            List.map (\code -> StringCompare.prefixKey prefix (code + n)) codes

        d =
            List.foldl (\( code, key ) acc -> SeqDict.insert key code acc) SeqDict.empty (List.map2 Tuple.pair codes present)

        hits =
            List.foldl (\_ acc -> countMembers d absent (countMembers d present acc)) 0 (List.range 1 rounds)
    in
    (SeqDict.size d == n)
        && (hits == rounds * n)
        && (SeqDict.foldl (\_ v s -> s + v) 0 d == TypeKeys.triangle n)


benchPrefixKeyFresh : Int -> Bool
benchPrefixKeyFresh n =
    let
        prefix =
            StringCompare.prefixOf 2000

        codes =
            permutation n

        d =
            prefixDict prefix codes

        hits =
            List.foldl
                (\_ acc ->
                    List.foldl
                        (\code c ->
                            let
                                c1 =
                                    if SeqDict.member (StringCompare.prefixKey prefix code) d then
                                        c + 1

                                    else
                                        c
                            in
                            if SeqDict.member (StringCompare.prefixKey prefix (code + n)) d then
                                c1 + 1

                            else
                                c1
                        )
                        acc
                        codes
                )
                0
                (List.range 1 rounds)
    in
    (SeqDict.size d == n)
        && (hits == rounds * n)
        && (SeqDict.foldl (\_ v s -> s + v) 0 d == TypeKeys.triangle n)


benchCollide : Int -> Bool
benchCollide n =
    let
        prefix =
            StringCompare.prefixOf 4107

        tail code =
            StringCompare.prefixKey prefix code ++ String.repeat 93 "z"

        codes =
            permutation n

        d =
            List.foldl (\code acc -> SeqDict.insert (tail code) code acc) SeqDict.empty codes

        hits =
            countMembers d (List.map (\code -> tail (code + n)) codes) (countMembers d (List.map tail codes) 0)
    in
    (SeqDict.size d == n)
        && (hits == n)
        && (SeqDict.foldl (\_ v s -> s + v) 0 d == TypeKeys.triangle n)


benchMultiLookup : Int -> Bool
benchMultiLookup n =
    let
        -- distinct codes below 20^6, so distinct trees (7919 is prime to 20^6)
        keyOf i =
            TypeKeys.topOfCode 20 (modBy 64000000 (i * 7919 + 13))

        indexed =
            List.map (\i -> ( i, keyOf i )) (List.range 0 (n - 1))

        every m =
            List.foldl
                (\( i, k ) acc ->
                    if modBy m i == 0 then
                        SeqDict.insert k i acc

                    else
                        acc
                )
                SeqDict.empty
                indexed

        d1 =
            every 2

        d2 =
            every 3

        d3 =
            every 5

        ( hits, all ) =
            List.foldl
                (\( i, k ) ( h, d ) ->
                    ( if SeqDict.member k d1 && SeqDict.member k d2 && SeqDict.member k d3 then
                        h + 1

                      else
                        h
                    , case SeqDict.get k d of
                        Just _ ->
                            d

                        Nothing ->
                            SeqDict.insert k i d
                    )
                )
                ( 0, d1 )
                indexed
    in
    (hits == (n + 29) // 30)
        && (SeqDict.size all == n)
        && (SeqDict.foldl (\_ v s -> s + v) 0 all == TypeKeys.triangle n)


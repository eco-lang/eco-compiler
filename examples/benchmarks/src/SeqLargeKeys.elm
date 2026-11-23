module SeqLargeKeys exposing (benchIntern, benchLongKey, benchLongKeyReuse)

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

-}

import Array
import SeqDict exposing (SeqDict)
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

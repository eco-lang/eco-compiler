module StringCompare exposing (benchComparePrefix, benchEqPrefix, benchEqSame, prefixKey, prefixOf)

{-| Comparisons of long Strings that share a long common prefix, so that every comparison has to
read the whole prefix before it finds the first difference (or the end).

  - `benchEqPrefix` (string-eq-prefix) compares 2,000 distinct keys of 4,000 characters, each
    with the next, `size` times over. The keys differ only in their last six characters, so every
    `==` reads about 4,000 characters to answer `False`. A cached String hash would answer it at
    once when both keys had been hashed before.
  - `benchEqSame` (string-eq-same) compares each of the same keys with an equal copy built
    separately, `size` times over: every `==` reads all of both Strings and answers `True`. No
    hash can shorten that.
  - `benchComparePrefix` (string-compare-prefix) sorts `size` keys of 2,000 characters that share
    all but their last six, so every `compare` reads the prefix. Ordering cannot use a hash.

Checked in closed form: the counts of equal and unequal pairs, and the sorted keys against the
keys built in order.

-}


{-| The shared part of every key of length `len`: all but its last seven characters.
-}
prefixOf : Int -> String
prefixOf len =
    String.left (len - 7) (String.repeat (len // 10 + 1) "abcdefghij")


{-| The key numbered `code` (0 to 999,999): `prefix`, then `#` and `code` as six digits, so keys
order as their codes do.
-}
prefixKey : String -> Int -> String
prefixKey prefix code =
    prefix ++ "#" ++ String.padLeft 6 '0' (String.fromInt code)


{-| A permutation of `0 .. n-1` (when `n` is not a multiple of 7,919).
-}
codeAt : Int -> Int -> Int
codeAt n i =
    modBy n (i * 7919 + 13)


keyCount : Int
keyCount =
    2000


countPairs : Bool -> Int -> List ( String, String ) -> Int
countPairs want rounds pairs =
    List.foldl
        (\_ acc ->
            List.foldl
                (\( a, b ) c ->
                    if (a == b) == want then
                        c + 1

                    else
                        c
                )
                acc
                pairs
        )
        0
        (List.range 1 rounds)


benchEqPrefix : Int -> Bool
benchEqPrefix rounds =
    let
        prefix =
            prefixOf 4000

        keys =
            List.map (\i -> prefixKey prefix (codeAt keyCount i)) (List.range 0 (keyCount - 1))
    in
    countPairs False rounds (List.map2 Tuple.pair keys (List.drop 1 keys)) == rounds * (keyCount - 1)


benchEqSame : Int -> Bool
benchEqSame rounds =
    let
        prefix =
            prefixOf 4000

        codes =
            List.map (codeAt keyCount) (List.range 0 (keyCount - 1))

        keys =
            List.map (prefixKey prefix) codes

        copies =
            List.map (prefixKey (prefixOf 4000)) codes
    in
    countPairs True rounds (List.map2 Tuple.pair keys copies) == rounds * keyCount


benchComparePrefix : Int -> Bool
benchComparePrefix n =
    let
        prefix =
            prefixOf 2000
    in
    List.sort (List.map (\i -> prefixKey prefix (codeAt n i)) (List.range 0 (n - 1)))
        == List.map (prefixKey prefix) (List.range 0 (n - 1))

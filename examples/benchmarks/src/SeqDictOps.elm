module SeqDictOps exposing (benchChurn, benchEquality, benchIterate, benchSmall, benchUpdate)

{-| Workloads for the parts of eco/system's `SeqDict` that `SeqDictKeys` does not reach: removal,
in-place updates, iteration, many small dicts and equality. A `SeqDict` keeps its entries twice,
in a hash trie for lookups and in an insertion-ordered array for iteration, so each workload says
which of the two it stresses.

  - `benchChurn` (seqdict-churn): a sliding window of 1,024 live keys over `n` inserts, each
    insert followed by the removal of the key that left the window and a lookup inside it. Trie
    removal, and the order array's holes and its rebuilds once fewer than 80 % of its slots are
    live. Checked by the hit count in closed form, and the final entries against the window's
    keys in insertion order.
  - `benchUpdate` (seqdict-update): `SeqDict.update` counts of `n` pseudo-random keys from a range
    of `n / 16`, so most updates replace a value already present. Checked against counts kept in
    an `Array Int` over a second copy of the sequence.
  - `benchIterate` (seqdict-iterate): ten passes of `foldl`, `foldr`, `toList`, `keys`, `values`,
    `map` and `filter` over one dict of `n` entries. The order array. Checked in closed form.
  - `benchSmall` (seqdict-small): `n` dicts of 1 to 8 entries, each built with `fromList` and
    probed with every key and one miss. Checked by a loop that counts the same without a
    `SeqDict`.
  - `benchEquality` (seqdict-equality): `==` and `unorderedEquals` on dicts of `n` entries built in
    the same order, in reverse order and with one value changed, ten times. Checked by the known
    answers.

-}

import Array
import SeqDict exposing (SeqDict)



-- CHURN


window : Int
window =
    1024


benchChurn : Int -> Bool
benchChurn n =
    let
        step i ( d, hits ) =
            let
                inserted =
                    SeqDict.insert i i d

                trimmed =
                    if i >= window then
                        SeqDict.remove (i - window) inserted

                    else
                        inserted

                hit =
                    case SeqDict.get (i - window // 2) trimmed of
                        Just _ ->
                            1

                        Nothing ->
                            0
            in
            ( trimmed, hits + hit )

        ( final, totalHits ) =
            List.foldl step ( SeqDict.empty, 0 ) (List.range 0 (n - 1))

        live =
            List.range (max 0 (n - window)) (n - 1)
    in
    (totalHits == max 0 (n - window // 2))
        && (SeqDict.size final == List.length live)
        && (SeqDict.toList final == List.map (\k -> ( k, k )) live)



-- UPDATE


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| `n` pseudo-random values in `0 .. range - 1`, in the order they are drawn.
-}
draws : Int -> Int -> List Int
draws n range =
    let
        go i seed acc =
            if i <= 0 then
                List.reverse acc

            else
                let
                    s =
                        next seed
                in
                go (i - 1) s (modBy range s :: acc)
    in
    go n 1 []


benchUpdate : Int -> Bool
benchUpdate n =
    let
        range =
            max 1 (n // 16)

        counts =
            List.foldl
                (\v d -> SeqDict.update v (\m -> Just (1 + Maybe.withDefault 0 m)) d)
                SeqDict.empty
                (draws n range)

        reference =
            List.foldl (\v a -> Array.set v (1 + Maybe.withDefault 0 (Array.get v a)) a) (Array.repeat range 0) (draws n range)

        distinct =
            Array.foldl
                (\c k ->
                    if c > 0 then
                        k + 1

                    else
                        k
                )
                0
                reference
    in
    (SeqDict.size counts == distinct)
        && SeqDict.foldl (\k c ok -> ok && Array.get k reference == Just c) True counts
        && (SeqDict.foldl (\_ c s -> s + c) 0 counts == n)



-- ITERATE


benchIterate : Int -> Bool
benchIterate n =
    let
        d =
            SeqDict.fromList (List.map (\k -> ( k, 3 * k )) (List.range 0 (n - 1)))

        -- 0 + 1 + ... + (n - 1), with the even factor halved first (see ListFold)
        triangle =
            if modBy 2 n == 0 then
                (n // 2) * (n - 1)

            else
                n * ((n - 1) // 2)

        -- the even keys below n: 0 + 2 + ... = 2 * (0 + 1 + ... + (evens - 1))
        evens =
            (n + 1) // 2

        evenSum =
            evens * (evens - 1)

        pass _ ok =
            ok
                && (SeqDict.foldl (\_ v s -> s + v) 0 d == 3 * triangle)
                && (SeqDict.foldr (\k _ s -> s + k) 0 d == triangle)
                && (List.length (SeqDict.toList d) == n)
                && (List.sum (SeqDict.keys d) == triangle)
                && (List.sum (SeqDict.values d) == 3 * triangle)
                && (SeqDict.foldl (\_ v s -> s + v) 0 (SeqDict.map (\_ v -> v + 1) d) == 3 * triangle + n)
                && (SeqDict.foldl (\k _ s -> s + k) 0 (SeqDict.filter (\k _ -> modBy 2 k == 0) d) == evenSum)
    in
    List.foldl pass True (List.range 1 10)



-- SMALL


benchSmall : Int -> Bool
benchSmall n =
    let
        probe i ( hits, sum ) =
            let
                m =
                    1 + modBy 8 i

                base =
                    i * 31

                d =
                    SeqDict.fromList (List.map (\j -> ( base + j, j )) (List.range 0 (m - 1)))
            in
            List.foldl
                (\j ( h, s ) ->
                    case SeqDict.get (base + j) d of
                        Just v ->
                            ( h + 1, s + v )

                        Nothing ->
                            ( h, s )
                )
                ( hits, sum )
                (List.range 0 m)

        expectedCounts i ( hits, sum ) =
            let
                m =
                    1 + modBy 8 i
            in
            ( hits + m, sum + m * (m - 1) // 2 )
    in
    List.foldl probe ( 0, 0 ) (List.range 0 (n - 1))
        == List.foldl expectedCounts ( 0, 0 ) (List.range 0 (n - 1))



-- EQUALITY


benchEquality : Int -> Bool
benchEquality n =
    let
        -- a permutation of 0 .. n-1 unless n is a multiple of 7919 (see SeqDictKeys)
        keys =
            List.map (\i -> modBy n (i * 7919 + 13)) (List.range 0 (n - 1))

        pairs =
            List.map (\k -> ( k, 2 * k )) keys

        a =
            SeqDict.fromList pairs

        same =
            SeqDict.fromList pairs

        reversed =
            SeqDict.fromList (List.reverse pairs)

        -- key 0 is always present, with value 0; inserting it again keeps its place
        changed =
            SeqDict.insert 0 -1 same

        pass _ ok =
            ok
                && (a == same)
                && ((a == reversed) == (SeqDict.size a < 2))
                && SeqDict.unorderedEquals a reversed
                && not (SeqDict.unorderedEquals a changed)
    in
    List.foldl pass True (List.range 1 10)

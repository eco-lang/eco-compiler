module PairKeys exposing (benchCharPairs, benchFloatPairs)

{-| Containers keyed by pairs of unboxed values, where every comparison compares two tuples:

  - `dict-char-pairs` counts the bigrams of `n` characters of generated text in a
    `Dict ( Char, Char ) Int`.
  - `set-float-pairs` puts `n` points, a quarter of them distinct, in a `Set ( Float, Float )`.

Checked at every size without the container: the bigram counts against an `Array` indexed by
the two letters, and the set's size and coordinate sums against the generator's closed form.

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Set exposing (Set)


{-| The `i`-th letter of the text: 'a' to 'z', or a space.
-}
letterAt : Int -> Int
letterAt i =
    modBy 27 (i * 7 + modBy 11 (i * i))


toChar : Int -> Char
toChar k =
    if k == 26 then
        ' '

    else
        Char.fromCode (97 + k)


bigrams : Int -> Dict ( Char, Char ) Int
bigrams n =
    let
        go : Int -> Char -> Dict ( Char, Char ) Int -> Dict ( Char, Char ) Int
        go i prev acc =
            if i >= n then
                acc

            else
                let
                    c =
                        toChar (letterAt i)
                in
                go (i + 1)
                    c
                    (Dict.update ( prev, c )
                        (\m -> Just (Maybe.withDefault 0 m + 1))
                        acc
                    )
    in
    go 1 (toChar (letterAt 0)) Dict.empty


expectedBigrams : Int -> Array Int
expectedBigrams n =
    List.foldl
        (\i acc ->
            let
                k =
                    letterAt (i - 1) * 27 + letterAt i
            in
            Array.set k (Maybe.withDefault 0 (Array.get k acc) + 1) acc
        )
        (Array.repeat (27 * 27) 0)
        (List.range 1 (n - 1))


indexOf : Char -> Int
indexOf c =
    if c == ' ' then
        26

    else
        Char.toCode c - 97


benchCharPairs : Int -> Bool
benchCharPairs n =
    let
        counts =
            bigrams n

        want =
            expectedBigrams n

        countsMatch =
            Dict.foldl
                (\( a, b ) v ok -> ok && Array.get (indexOf a * 27 + indexOf b) want == Just v)
                True
                counts

        total =
            Dict.foldl (\_ v s -> s + v) 0 counts

        present =
            List.length (List.filter (\v -> v > 0) (Array.toList want))
    in
    countsMatch && total == n - 1 && Dict.size counts == present


{-| The `i`-th point: `j = i mod d` for `d` a quarter of `n`, then `j mod 1000` and `j mod 999`
in quarters, so points repeat with period `d` and are distinct within it (1000 and 999 are
coprime, so `j` up to 998,999 gives distinct pairs).
-}
pointAt : Int -> Int -> ( Float, Float )
pointAt d i =
    let
        j =
            modBy d i
    in
    ( toFloat (modBy 1000 j) / 4, toFloat (modBy 999 j) / 4 )


benchFloatPairs : Int -> Bool
benchFloatPairs n =
    let
        d =
            max 1 (n // 4)

        points =
            Set.fromList (List.map (pointAt d) (List.range 0 (n - 1)))

        distinct =
            min d n

        ( sx, sy ) =
            Set.foldl (\( x, y ) ( ax, ay ) -> ( ax + x, ay + y )) ( 0, 0 ) points

        ( ex, ey ) =
            List.foldl
                (\j ( ax, ay ) -> ( ax + toFloat (modBy 1000 j) / 4, ay + toFloat (modBy 999 j) / 4 ))
                ( 0, 0 )
                (List.range 0 (distinct - 1))
    in
    Set.size points == distinct && sx == ex && sy == ey

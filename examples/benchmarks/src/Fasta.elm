module Fasta exposing (bench, output)

{-| fasta: generate DNA sequences in FASTA format, 60 characters a line: `2n` characters
repeating a fixed sequence, then `3n` and `5n` characters drawn at random (a linear
congruential generator) from two weighted alphabets. String building.
-}

import Output


alu : String
alu =
    "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG"
        ++ "GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA"
        ++ "CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT"
        ++ "ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA"
        ++ "GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG"
        ++ "AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC"
        ++ "AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"


iub : List ( Char, Float )
iub =
    List.map2 Tuple.pair
        (String.toList "acgtBDHKMNRSVWY")
        ([ 0.27, 0.12, 0.12, 0.27 ] ++ List.repeat 11 0.02)


homoSapiens : List ( Char, Float )
homoSapiens =
    [ ( 'a', 0.302954942668 )
    , ( 'c', 0.1979883004921 )
    , ( 'g', 0.1975473066391 )
    , ( 't', 0.3015094502008 )
    ]


width : Int
width =
    60


{-| `n` characters of `src` repeated, as lines.
-}
repeatFasta : String -> Int -> List String
repeatFasta src n =
    let
        r =
            String.length src

        s =
            src ++ src ++ String.left (modBy r n) src

        full =
            List.range 0 (n // width - 1)
                |> List.map (\j -> String.slice (modBy r (j * width)) (modBy r (j * width) + width) s)
    in
    if modBy width n == 0 then
        full

    else
        full ++ [ String.right (modBy width n) s ]


{-| The table with each weight replaced by the running total.
-}
cumulative : List ( Char, Float ) -> List ( Char, Float )
cumulative table =
    List.foldl (\( c, p ) ( acc, total ) -> ( ( c, total + p ) :: acc, total + p )) ( [], 0 ) table
        |> Tuple.first
        |> List.reverse


nextRandom : Int -> Int
nextRandom seed =
    modBy 139968 (seed * 3877 + 29573)


{-| The first character whose running total exceeds `r`.
-}
pick : Float -> List ( Char, Float ) -> Char
pick r table =
    case table of
        [ ( c, _ ) ] ->
            c

        ( c, p ) :: rest ->
            if p > r then
                c

            else
                pick r rest

        [] ->
            ' '


randomLine : List ( Char, Float ) -> Int -> Int -> List Char -> ( String, Int )
randomLine table count seed acc =
    if count <= 0 then
        ( String.fromList (List.reverse acc), seed )

    else
        let
            s =
                nextRandom seed
        in
        randomLine table (count - 1) s (pick (toFloat s / 139968) table :: acc)


{-| `n` random characters as lines, continuing from `seed`; gives the seed it ends with.
-}
randomFasta : List ( Char, Float ) -> Int -> Int -> ( List String, Int )
randomFasta table n seed =
    let
        go remaining s lines =
            if remaining <= 0 then
                ( List.reverse lines, s )

            else
                let
                    ( line, s2 ) =
                        randomLine table (min width remaining) s []
                in
                go (remaining - width) s2 (line :: lines)
    in
    go n seed []


{-| The benchmark's standard output.
-}
output : Int -> String
output n =
    let
        ( two, seed ) =
            randomFasta (cumulative iub) (n * 3) 42

        ( three, _ ) =
            randomFasta (cumulative homoSapiens) (n * 5) seed
    in
    String.join "\n"
        ((">ONE Homo sapiens alu" :: repeatFasta alu (n * 2))
            ++ (">TWO IUB ambiguity codes" :: two)
            ++ (">THREE Homo sapiens frequency" :: three)
        )
        ++ "\n"


bench : Int -> Int
bench n =
    Output.checksum (output n)

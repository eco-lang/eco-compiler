module KNucleotide exposing (bench, output)

{-| k-nucleotide (Benchmarks Game): read the THREE sequence of the fasta output, then count every
k-nucleotide in it with a `Dict String Int`: the frequencies of every 1- and 2-nucleotide, and
the counts of GGT, GGTA, GGTATT, GGTATTTTAATT and GGTATTTTAATTTATAGT. Every key is a `String`,
so this measures `Dict` with string comparison, and `String.slice`.

At every size, each length's counts must add up to the number of positions, `length - k + 1`
(or none, when the sequence is shorter than `k`). At the sizes in `known` the output must also
match exactly, by its checksum: 1,000 is the Benchmarks Game's published reference output, the
others come from a Python implementation of fasta and k-nucleotide that reproduces the published
fasta and k-nucleotide outputs at 1,000 exactly.

-}

import Dict exposing (Dict)
import Fasta
import Output


{-| The THREE sequence of `Fasta.output n`, upper case, as one string.
-}
sequence : Int -> String
sequence n =
    let
        afterHeader lines =
            case lines of
                [] ->
                    []

                line :: rest ->
                    if String.startsWith ">THREE" line then
                        rest

                    else
                        afterHeader rest
    in
    Fasta.output n
        |> String.lines
        |> afterHeader
        |> String.concat
        |> String.toUpper


increment : Maybe Int -> Maybe Int
increment count =
    Just (Maybe.withDefault 0 count + 1)


{-| The count of every `k`-nucleotide in the sequence.
-}
frequencies : Int -> String -> Dict String Int
frequencies k dna =
    let
        last =
            String.length dna - k

        go i counts =
            if i > last then
                counts

            else
                go (i + 1) (Dict.update (String.slice i (i + k) dna) increment counts)
    in
    go 0 Dict.empty


fragments : List String
fragments =
    [ "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT" ]


type alias Report =
    { length : Int
    , tables : List ( Int, Dict String Int )
    }


{-| Count every length the output needs: 1 and 2 for the frequencies, then each fragment's.
-}
run : Int -> Report
run n =
    let
        dna =
            sequence n
    in
    Report (String.length dna) (List.map (\k -> ( k, frequencies k dna )) (1 :: 2 :: List.map String.length fragments))


table : Int -> Report -> Dict String Int
table k report =
    case List.filter (\( length, _ ) -> length == k) report.tables of
        ( _, counts ) :: _ ->
            counts

        [] ->
            Dict.empty


{-| Descending frequency, then ascending key, each as a percentage with three decimals.
-}
frequencyLines : Int -> Report -> String
frequencyLines k report =
    let
        total =
            toFloat (report.length - k + 1)
    in
    Dict.toList (table k report)
        |> List.sortWith
            (\( ka, ca ) ( kb, cb ) ->
                case compare cb ca of
                    EQ ->
                        compare ka kb

                    order ->
                        order
            )
        |> List.map (\( key, count ) -> key ++ " " ++ Output.fixed3 (100 * toFloat count / total) ++ "\n")
        |> String.concat


format : Report -> String
format report =
    frequencyLines 1 report
        ++ "\n"
        ++ frequencyLines 2 report
        ++ "\n"
        ++ String.concat
            (List.map
                (\f -> String.fromInt (Maybe.withDefault 0 (Dict.get f (table (String.length f) report))) ++ "\t" ++ f ++ "\n")
                fragments
            )


{-| The benchmark's standard output.
-}
output : Int -> String
output n =
    format (run n)


{-| `( n, checksum of the output )`.
-}
known : List ( Int, Int )
known =
    [ ( 1000, 447089901 ), ( 9000, 767393306 ) ]


bench : Int -> Bool
bench n =
    let
        report =
            run n

        positionsAddUp =
            List.all (\( k, counts ) -> Dict.foldl (\_ c sum -> sum + c) 0 counts == max 0 (report.length - k + 1)) report.tables

        matchesKnown =
            case List.filter (\( size, _ ) -> size == n) known of
                ( _, expected ) :: _ ->
                    Output.checksum (format report) == expected

                [] ->
                    True
    in
    positionsAddUp && matchesKnown

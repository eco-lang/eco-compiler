module RevComp exposing (bench, output)

{-| reverse-complement (Benchmarks Game): for each sequence of the fasta output, write its header
and then its reverse complement (the IUB code table: A and T, C and G, and so on), in lines of
60. `String.reverse`, `String.map` and string slicing over long strings.

The complement of the complement is the original, upper-cased, so reverse-complementing every
sequence twice must give back its input at every size. At the sizes in `known` the output must
also match exactly, by its checksum: 1,000 is the Benchmarks Game's published reference output,
the others from a Python implementation of fasta and reverse-complement that reproduces the
published fasta and reverse-complement outputs at 1,000 exactly.

-}

import Fasta
import Output


type alias Section =
    { header : String
    , dna : String
    }


{-| The sections of a FASTA text: each header line with its sequence joined into one string.
-}
sections : String -> List Section
sections text =
    let
        close header lines acc =
            Section header (String.concat (List.reverse lines)) :: acc

        go lines current acc =
            case ( lines, current ) of
                ( [], Just ( header, body ) ) ->
                    List.reverse (close header body acc)

                ( [], Nothing ) ->
                    List.reverse acc

                ( line :: rest, _ ) ->
                    if String.startsWith ">" line then
                        case current of
                            Just ( header, body ) ->
                                go rest (Just ( line, [] )) (close header body acc)

                            Nothing ->
                                go rest (Just ( line, [] )) acc

                    else
                        case current of
                            Just ( header, body ) ->
                                go rest (Just ( header, line :: body )) acc

                            Nothing ->
                                go rest Nothing acc
    in
    go (List.filter (not << String.isEmpty) (String.lines text)) Nothing []


complement : Char -> Char
complement c =
    case Char.toUpper c of
        'A' ->
            'T'

        'C' ->
            'G'

        'G' ->
            'C'

        'T' ->
            'A'

        'U' ->
            'A'

        'M' ->
            'K'

        'R' ->
            'Y'

        'W' ->
            'W'

        'S' ->
            'S'

        'Y' ->
            'R'

        'K' ->
            'M'

        'V' ->
            'B'

        'H' ->
            'D'

        'D' ->
            'H'

        'B' ->
            'V'

        'N' ->
            'N'

        other ->
            other


reverseComplement : String -> String
reverseComplement dna =
    String.map complement (String.reverse dna)


{-| `dna` in lines of 60, each ending in a newline.
-}
wrap : String -> String
wrap dna =
    let
        go i acc =
            if i >= String.length dna then
                List.reverse acc

            else
                go (i + 60) (String.slice i (i + 60) dna :: acc)
    in
    String.concat (List.map (\line -> line ++ "\n") (go 0 []))


format : List Section -> String
format reversed =
    String.concat (List.map (\s -> s.header ++ "\n" ++ wrap s.dna) reversed)


run : Int -> ( List Section, List Section )
run n =
    let
        input =
            sections (Fasta.output n)
    in
    ( input, List.map (\s -> { s | dna = reverseComplement s.dna }) input )


{-| The benchmark's standard output.
-}
output : Int -> String
output n =
    format (Tuple.second (run n))


{-| `( n, checksum of the output )`.
-}
known : List ( Int, Int )
known =
    [ ( 1000, 255518806 ), ( 70000, 941129043 ) ]


bench : Int -> Bool
bench n =
    let
        ( input, reversed ) =
            run n

        involution =
            List.map2 (\i r -> reverseComplement r.dna == String.toUpper i.dna) input reversed
                |> List.all identity

        matchesKnown =
            case List.filter (\( size, _ ) -> size == n) known of
                ( _, expected ) :: _ ->
                    Output.checksum (format reversed) == expected

                [] ->
                    True
    in
    List.length reversed == 3 && involution && matchesKnown

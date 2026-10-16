module StringBuild exposing (benchAppend, benchConcat, benchJoin)

{-| The same text, `n` generated pieces of 1 to 12 characters, built three ways:

  - `string-append`: `++` onto the growing string, one piece at a time (on eco, long strings
    become ropes instead of being copied);
  - `string-join`: `String.join " "` of the pieces;
  - `string-concat`: `String.concat` of the pieces with their separators.

Checked at every size without reading the built string a second way: its length must be the sum
of the piece lengths and separators, and its checksum (`Output.checksum`'s polynomial) must equal
the one combined from the pieces' own checksums (`h(a ++ b) = h(a) * 31^length(b) + h(b)`).

-}

import Output


pieces : Int -> List String
pieces n =
    List.map (\i -> String.left (1 + modBy 12 (i * 7)) ("abcdefghijkl" |> String.dropLeft (modBy 5 i))) (List.range 0 (n - 1))


modulus : Int
modulus =
    1000000007


power31 : Int -> Int
power31 k =
    if k <= 0 then
        1

    else
        modBy modulus (31 * power31 (k - 1))


{-| `a * b` modulo 1000000007, in 16-bit halves of `b`: the plain product can reach 10^18,
beyond the 2^53 the JavaScript backends hold exactly.
-}
mulMod : Int -> Int -> Int
mulMod a b =
    modBy modulus (modBy modulus (a * (b // 65536)) * 65536 + a * modBy 65536 b)


{-| The checksum and length of the pieces joined with single spaces, from the pieces alone.
-}
expected : List String -> ( Int, Int )
expected ps =
    List.foldl
        (\p ( h, len, first ) ->
            let
                part =
                    if first then
                        p

                    else
                        " " ++ p

                l =
                    String.length part
            in
            ( modBy modulus (mulMod h (power31 l) + Output.checksum part), len + l, False )
        )
        ( 0, 0, True )
        ps
        |> (\( h, len, _ ) -> ( h, len ))


check : List String -> String -> Bool
check ps text =
    ( Output.checksum text, String.length text ) == expected ps


benchAppend : Int -> Bool
benchAppend n =
    let
        ps =
            pieces n

        text =
            case ps of
                first :: rest ->
                    List.foldl (\p acc -> acc ++ " " ++ p) first rest

                [] ->
                    ""
    in
    check ps text


benchJoin : Int -> Bool
benchJoin n =
    let
        ps =
            pieces n
    in
    check ps (String.join " " ps)


benchConcat : Int -> Bool
benchConcat n =
    let
        ps =
            pieces n
    in
    check ps (String.concat (List.intersperse " " ps))

module Compiler.AST.StringTableTest exposing (suite)

{-| Tests that a string table, written out as a preamble and read back, decodes
string references to the strings they were encoded from.

A string table, from `Compiler.AST.StringTable`, lists every distinct string
once, and the encoded body refers to a string by its index in that list. Each
index is written in a fixed number of bytes, the table's width, which `build`
chooses from the number of strings. If `tableDecoder` and `tableEncoder`
disagreed, or a reference were read at the wrong width, decoding could still
succeed and give back the wrong strings, because `stringDec` turns an index
outside the table into the empty string rather than failing.

The fixture for a size `n` is the table `build` makes from the strings `"s1"`
to `"s<n>"`. Sizes 3, 300 and 70,000 fall in the ranges for which `build`
chooses widths of 1, 2 and 4 bytes. The table is sorted as strings, so `"s1"`
is at index 0; in the 300- and 70,000-string tables the others are not in
numeric order (`"s10"` follows `"s1"`). The probes are `"s1"` and `"s<n>"`,
encoded with `string` after the table's preamble in one byte sequence.

What the tests establish:

  - "width 1 (3 strings)", "width 2 (300 strings)" and "width 4 (70,000
    strings)" each decode the preamble and the two probes, and check that the
    decode succeeds, that the decoded table's `idxToStr` lists the same strings
    in the same order as the built table's, that its width equals the built
    table's, and that `stringDec` with the decoded table gives back `"s1"` and
    `"s<n>"`. The decoded table's `strToIdx` is not compared, since
    `tableDecoder` leaves it empty.

Among what is not tested:

  - The width itself. The decoded width is compared with the built width, never
    with 1, 2 or 4, so the tests would not notice `build` choosing a wider
    width than needed, nor, for the 300-string table, width 1, since both
    probes' indices fit in one byte.
  - Sizes at the edges of the width ranges, and the empty table.
  - The `disabled` table, with which strings are written inline.
  - A string missing from the table. `string` encodes it as index 0, which is
    also the index of the probe `"s1"`.
  - References to strings other than the two probes, and whether decoding
    consumes every byte.

-}

import Array
import Bytes.Decode as BD
import Bytes.Encode as BE
import Compiler.AST.StringTable as StringTable
import Expect
import Set
import Test exposing (Test)


{-| Returns the `n` strings `"s1"` to `"s<n>"`, in numeric order.
-}
strings : Int -> List String
strings n =
    List.map (\i -> "s" ++ String.fromInt i) (List.range 1 n)


{-| Checks a round trip through a table built from `strings n`.

Encodes the table's preamble followed by references to the first and last of
those strings, decodes the bytes with `tableDecoder` and `stringDec`, and expects
the decoded table's `idxToStr` and width to equal the built table's and the two
references to decode to the strings they were encoded from. A decode that fails
fails the expectation.

-}
roundTrip : Int -> Expect.Expectation
roundTrip n =
    let
        table =
            StringTable.build (Set.fromList (strings n))

        probe =
            List.filterMap identity [ List.head (strings n), List.head (List.reverse (strings n)) ]

        bytes =
            BE.encode (BE.sequence (StringTable.tableEncoder table :: List.map (StringTable.string table) probe))

        decoded =
            BD.decode
                (StringTable.tableDecoder
                    |> BD.andThen
                        (\t ->
                            BD.map2 (\_ ps -> ( t, ps ))
                                (BD.succeed ())
                                (List.foldr (\_ acc -> BD.map2 (::) (StringTable.stringDec t) acc) (BD.succeed []) probe)
                        )
                )
                bytes
    in
    case decoded of
        Just ( t, ps ) ->
            Expect.all
                [ \_ -> Expect.equal (Array.toList table.idxToStr) (Array.toList t.idxToStr)
                , \_ -> Expect.equal table.width t.width
                , \_ -> Expect.equal probe ps
                ]
                ()

        Nothing ->
            Expect.fail "decode failed"


{-| The round trips at tables of 3, 300 and 70,000 strings, one test each.
-}
suite : Test
suite =
    Test.describe "StringTable decode (cache-serialization S11a)"
        [ Test.test "width 1 (3 strings)" <| \_ -> roundTrip 3
        , Test.test "width 2 (300 strings)" <| \_ -> roundTrip 300
        , Test.test "width 4 (70,000 strings)" <| \_ -> roundTrip 70000
        ]

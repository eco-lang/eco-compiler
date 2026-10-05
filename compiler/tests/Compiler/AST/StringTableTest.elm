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
numeric order (`"s10"` follows `"s1"`). The probes are the strings at sorted
indices 1 and `n - 1` (the last), and `"s<n>"`, encoded with `string` after the
table's preamble in one byte sequence. No probe sits at index 0, the index
`string` writes for a string missing from the table, and the last one's index
does not fit in a narrower width than the table's.

What the tests establish:

  - "width 1 (3 strings)", "width 2 (300 strings)" and "width 4 (70,000
    strings)" each check that `build` chose that width, that the probe
    references take exactly that many bytes each, and that decoding the
    preamble and the probes succeeds, gives a table whose `idxToStr` lists the
    same strings in the same order as the built table's and whose width is the
    same, and gives back the probes with `stringDec`. The decoded table's
    `strToIdx` is not compared, since `tableDecoder` leaves it empty.

Among what is not tested:

  - Sizes at the edges of the width ranges, and the empty table.
  - The `disabled` table, with which strings are written inline.
  - A string missing from the table.

-}

import Array
import Bytes
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


{-| Checks a round trip through a table built from `strings n`, which `build`
should give index width `expectedWidth`.

Encodes the table's preamble followed by references to the probes, decodes the
bytes with `tableDecoder` and `stringDec`, and expects the built width to be
`expectedWidth`, the references to take `expectedWidth` bytes each, the decoded
table's `idxToStr` and width to equal the built table's, and the references to
decode to the strings they were encoded from. A decode that fails fails the
expectation.

-}
roundTrip : Int -> Int -> Expect.Expectation
roundTrip n expectedWidth =
    let
        table =
            StringTable.build (Set.fromList (strings n))

        sorted =
            Array.toList table.idxToStr

        probe =
            List.filterMap identity
                [ List.head (List.drop 1 sorted)
                , List.head (List.reverse sorted)
                , List.head (List.reverse (strings n))
                ]

        preambleBytes =
            BE.encode (StringTable.tableEncoder table)

        bytes =
            BE.encode (BE.sequence (StringTable.tableEncoder table :: List.map (StringTable.string table) probe))

        decoded =
            BD.decode
                (StringTable.tableDecoder
                    |> BD.andThen
                        (\t ->
                            BD.map (\ps -> ( t, ps ))
                                (List.foldr (\_ acc -> BD.map2 (::) (StringTable.stringDec t) acc) (BD.succeed []) probe)
                        )
                )
                bytes
    in
    case decoded of
        Just ( t, ps ) ->
            Expect.all
                [ \_ -> Expect.equal expectedWidth table.width
                , \_ -> Expect.equal (Bytes.width preambleBytes + List.length probe * expectedWidth) (Bytes.width bytes)
                , \_ -> Expect.equal (Array.toList table.idxToStr) (Array.toList t.idxToStr)
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
        [ Test.test "width 1 (3 strings)" <| \_ -> roundTrip 3 1
        , Test.test "width 2 (300 strings)" <| \_ -> roundTrip 300 2
        , Test.test "width 4 (70,000 strings)" <| \_ -> roundTrip 70000 4
        ]

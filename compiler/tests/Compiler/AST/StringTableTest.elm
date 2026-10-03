module Compiler.AST.StringTableTest exposing (suite)

{-| Cache-serialization plan S11a: `tableDecoder` no longer builds the
encoder-only `strToIdx`; a decoded table must still give back the same
`idxToStr` / `width`, and `stringDec` must round-trip at every width.
-}

import Array
import Bytes.Decode as BD
import Bytes.Encode as BE
import Compiler.AST.StringTable as StringTable
import Expect
import Set
import Test exposing (Test)


strings : Int -> List String
strings n =
    List.map (\i -> "s" ++ String.fromInt i) (List.range 1 n)


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


suite : Test
suite =
    Test.describe "StringTable decode (cache-serialization S11a)"
        [ Test.test "width 1 (3 strings)" <| \_ -> roundTrip 3
        , Test.test "width 2 (300 strings)" <| \_ -> roundTrip 300
        , Test.test "width 4 (70,000 strings)" <| \_ -> roundTrip 70000
        ]

module StringLoneSurrogateTest exposing (main)

{-| Lone surrogates. Eco combines only a valid high-low pair into one Char; a
lone surrogate is a Char of its own unit value (value-representation.md).
Elm's JS kernels instead glue a high surrogate to ANY next unit (foldl/toList)
and a low surrogate to ANY previous unit (foldr) - a documented divergence that
keeps `String.fromList (String.toList s) == s` for every string.

`Char.fromCode` passes surrogate code points through. A high and a low half
written next to each other by fromList ARE a surrogate pair, so they read back
as one astral Char (as in JS).
-}

-- CHECK: lone_high_codes: [55357, 97]
-- CHECK: lone_low_codes: [56832, 55357]
-- CHECK: lone_roundtrip: True
-- CHECK: lone_rev_roundtrip: True
-- CHECK: lone_units: 2
-- CHECK: lone_foldr_codes: [97, 56832]
-- CHECK: lone_uncons: Just (55357, 1)
-- CHECK: halves_join: True
-- CHECK: halves_codes: [128512]


import Html exposing (text)


main =
    let
        loneHigh =
            String.fromList [ Char.fromCode 0xD83D, 'a' ]

        loneLow =
            String.fromList [ Char.fromCode 0xDE00, Char.fromCode 0xD83D ]

        lowAfterA =
            String.fromList [ 'a', Char.fromCode 0xDE00 ]

        halves =
            String.fromList [ Char.fromCode 0xD83D, Char.fromCode 0xDE00 ]

        _ =
            Debug.log "lone_high_codes" (List.map Char.toCode (String.toList loneHigh))

        _ =
            Debug.log "lone_low_codes" (List.map Char.toCode (String.toList loneLow))

        _ =
            Debug.log "lone_roundtrip" (String.fromList (String.toList loneHigh) == loneHigh)

        _ =
            Debug.log "lone_rev_roundtrip" (String.fromList (String.toList loneLow) == loneLow)

        _ =
            Debug.log "lone_units" (String.length loneHigh)

        _ =
            Debug.log "lone_foldr_codes" (String.foldr (\c acc -> Char.toCode c :: acc) [] lowAfterA)

        _ =
            Debug.log "lone_uncons"
                (String.uncons loneHigh
                    |> Maybe.map (\( c, rest ) -> ( Char.toCode c, String.length rest ))
                )

        _ =
            Debug.log "halves_join" (halves == "😀")

        _ =
            Debug.log "halves_codes" (List.map Char.toCode (String.toList halves))
    in
    text "done"

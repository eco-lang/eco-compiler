module CharAstralListHeadTest exposing (main)

{-| An astral Char stored unboxed as a list head (cons head kind 3) reads back
as the same code point through List.head, a pattern match and List.map, and
Debug.log prints the list with the Char itself.
-}

-- CHECK: head_code: Just 128512
-- CHECK: match_code: 119070
-- CHECK: list_codes: [128512, 97, 119070]
-- CHECK: list_show: ['😀', 'a']


import Html exposing (text)


secondCode : List Char -> Int
secondCode cs =
    case cs of
        _ :: c :: _ ->
            Char.toCode c

        _ ->
            -1


main =
    let
        cs =
            [ '😀', 'a', Char.fromCode 0x0001D11E ]

        _ =
            Debug.log "head_code" (Maybe.map Char.toCode (List.head cs))

        _ =
            Debug.log "match_code" (secondCode (List.drop 1 cs))

        _ =
            Debug.log "list_codes" (List.map Char.toCode cs)

        _ =
            Debug.log "list_show" [ '😀', 'a' ]
    in
    text "done"

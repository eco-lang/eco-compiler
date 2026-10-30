module CharAstralCustomFieldTest exposing (main)

{-| An astral Char stored unboxed in a custom-type field (slot kind 3) reads back
as the same code point through a case match, in a single-constructor and in a
multi-constructor type, and Debug.log prints the value with the Char itself.
-}

-- CHECK: box_code: 128512
-- CHECK: shape_codes: [128512,119070,-1]
-- CHECK: box_show: Box 3 '😀'


import Html exposing (text)


type Box
    = Box Int Char


type Shape
    = Dot Char
    | Pair Int Char
    | Empty


boxCode : Box -> Int
boxCode (Box _ c) =
    Char.toCode c


shapeCode : Shape -> Int
shapeCode s =
    case s of
        Dot c ->
            Char.toCode c

        Pair _ c ->
            Char.toCode c

        Empty ->
            -1


main =
    let
        _ =
            Debug.log "box_code" (boxCode (Box 3 '😀'))

        _ =
            Debug.log "shape_codes" (List.map shapeCode [ Dot '😀', Pair 1 (Char.fromCode 0x0001D11E), Empty ])

        _ =
            Debug.log "box_show" (Box 3 '😀')
    in
    text "done"

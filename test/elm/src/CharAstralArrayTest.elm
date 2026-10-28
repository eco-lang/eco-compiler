module CharAstralArrayTest exposing (main)

{-| An astral Char stored unboxed in an Array (JsArray push and set, in the tail
and in a tree node past 32 elements) reads back as the same code point.
-}

-- CHECK: arr_push: Just 128512
-- CHECK: arr_set_tail: Just 119070
-- CHECK: arr_set_tree: Just 128512
-- CHECK: arr_other: Just 97
-- CHECK: arr_string_ok: True


import Array
import Html exposing (text)


main =
    let
        small =
            Array.fromList [ 'a', 'b' ]
                |> Array.push '😀'

        tailSet =
            Array.set 0 (Char.fromCode 0x0001D11E) small

        big =
            Array.initialize 40 (\_ -> 'a')
                |> Array.set 5 '😀'

        _ =
            Debug.log "arr_push" (Maybe.map Char.toCode (Array.get 2 small))

        _ =
            Debug.log "arr_set_tail" (Maybe.map Char.toCode (Array.get 0 tailSet))

        _ =
            Debug.log "arr_set_tree" (Maybe.map Char.toCode (Array.get 5 big))

        _ =
            Debug.log "arr_other" (Maybe.map Char.toCode (Array.get 39 big))

        _ =
            Debug.log "arr_string_ok" (String.fromList (Array.toList small) == "ab😀")
    in
    text "done"

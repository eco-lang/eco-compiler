module CharAstralArrayTest exposing (main)

{-| An astral `Char`, one whose code point is above 0xFFFF and so lies outside the
Basic Multilingual Plane, keeps its code point when stored in an `Array`.

The test pushes U+1F600 onto a two-element array, sets index 0 of that array to
U+1D11E, and sets index 5 of a 40-element array to U+1F600. `Array.get` returns
each code point, an untouched element of the large array is still `'a'`, and
the small array converted back to a `String` equals `"ab😀"`.

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

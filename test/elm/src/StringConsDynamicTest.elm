module StringConsDynamicTest exposing (main)

{-| `String.cons` rebuilds a string from the `Char` and rest that `String.uncons` split it into.

`String.uncons "ab"` gives `Just ( 'a', "b" )`, and `String.cons 'a' "b"` is
`"ab"` again. The `Char` passed to `String.cons` is computed at run time, not
written as a literal.
-}

-- CHECK: out: "ab"


import Html exposing (text)


main =
    let
        src =
            "ab"

        rebuilt =
            case String.uncons src of
                Just ( c, rest ) ->
                    String.cons c rest

                Nothing ->
                    ""

        _ =
            Debug.log "out" rebuilt
    in
    text "done"

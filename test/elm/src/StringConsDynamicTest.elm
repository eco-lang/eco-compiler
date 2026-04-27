module StringConsDynamicTest exposing (main)

{-| `String.cons` (Elm_Kernel_String_cons) takes a uint16_t Char as its
first argument — same ABI exposure as Char.toCode. Exercise it with a Char
freshly derived from the kernel.
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

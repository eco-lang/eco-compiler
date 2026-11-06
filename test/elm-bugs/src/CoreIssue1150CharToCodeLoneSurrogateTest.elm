module CoreIssue1150CharToCodeLoneSurrogateTest exposing (main)

{-| `Char.toCode` returns NaN, typed as `Int`, for a lone surrogate.

<https://github.com/elm/core/issues/1150>

Elm 0.19.1 gives `Char.toCode (Char.fromCode 0xD800)` = `NaN`. A value of type `Int` must be an
integer.

-}

-- CHECK: {{code: [0-9]+(\n|$)}}

import Html exposing (text)


main =
    let
        _ =
            Debug.log "code" (Char.toCode (Char.fromCode 0xD800))
    in
    text "done"

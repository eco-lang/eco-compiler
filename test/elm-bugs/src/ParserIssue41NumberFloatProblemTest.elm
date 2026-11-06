module ParserIssue41NumberFloatProblemTest exposing (main)

{-| `Parser.Advanced.number` with `float = Err problem` reports `invalid` instead of that problem.

<https://github.com/elm/parser/issues/41>

`number` takes a `Result x (Float -> a)` per kind of literal, and the `Err` value is the problem to
report when that kind is seen (as it is for `hex`, `octal` and `binary`). For "1.5" with
`float = Err "no floats"`, Elm 0.19.1 (elm/parser 1.1.0) reports the `invalid` problem instead.

-}

-- CHECK: float: Err [{ col = 1, contextStack = [], problem = "no floats", row = 1 }]
-- CHECK: hex: Err [{ col = 1, contextStack = [], problem = "no hex", row = 1 }]

import Html exposing (text)
import Parser.Advanced as A


{-| Accepts decimal integers and reports a distinct problem string for every other kind of
number.
-}
numberParser : A.Parser Never String Int
numberParser =
    A.number
        { int = Ok identity
        , hex = Err "no hex"
        , octal = Err "no octal"
        , binary = Err "no binary"
        , float = Err "no floats"
        , invalid = "invalid"
        , expecting = "expecting"
        }


main =
    let
        _ =
            Debug.log "float" (A.run numberParser "1.5")

        _ =
            Debug.log "hex" (A.run numberParser "0x1F")
    in
    text "done"

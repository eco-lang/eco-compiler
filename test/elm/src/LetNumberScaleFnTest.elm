module LetNumberScaleFnTest exposing (main)

{-| A let-bound record of integer literals passed to a function that takes a record
of `Float`s is used at `Float`: `round (scale 1.5 p)` with
`p = { lo = 30, hi = 40 }` logs 105.

`scale` is annotated `Float -> { lo : Float, hi : Float } -> Float` and
returns `factor * pair.lo + factor * pair.hi`; nothing in `main` other than
that annotation fixes the fields to `Float`.

-}

-- CHECK: scale: 105

import Html exposing (text)


scale : Float -> { lo : Float, hi : Float } -> Float
scale factor pair =
    factor * pair.lo + factor * pair.hi


main =
    let
        p =
            { lo = 30, hi = 40 }

        result =
            round (scale 1.5 p)

        _ =
            Debug.log "scale" result
    in
    text "done"

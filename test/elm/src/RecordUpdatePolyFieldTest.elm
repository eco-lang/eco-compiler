module RecordUpdatePolyFieldTest exposing (main)

{-| Updating a function-typed field of a let-bound record whose function is polymorphic gives a record whose new function works.

`r` holds the identity function `\x -> x`, so its `f` field is polymorphic.
`{ r | f = \y -> y + 1 }` cannot change a field's type,
so it uses `r` with `f : Int -> Int`. `r2.f 5` gives 6 and `r2.g` keeps 0.
-}

-- CHECK: f: 6
-- CHECK: g: 0

import Html exposing (text)


main =
    let
        r =
            { f = \x -> x, g = 0 }

        r2 =
            { r | f = \y -> y + 1 }

        _ =
            Debug.log "f" (r2.f 5)

        _ =
            Debug.log "g" r2.g
    in
    text "done"

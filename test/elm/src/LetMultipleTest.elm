module LetMultipleTest exposing (main)

{-| Test let with multiple bindings.
-}

-- CHECK: sum: 15
-- CHECK: product: 120

import Html exposing (text)


main =
    let
        a = 1
        b = 2
        c = 3
        d = 4
        e = 5
        sum = a + b + c + d + e
        product = a * b * c * d * e
        _ = Debug.log "sum" sum
        _ = Debug.log "product" product
    in
    text "done"

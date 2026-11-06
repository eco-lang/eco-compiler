module LetMultipleTest exposing (main)

{-| Five Int bindings in one `let` combined by two later bindings: their sum (15) and
their product (120).
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

module CaseInLetTest exposing (main)

{-| Checks that a `case` expression on an `Order` can be the body of a `let`
binding, with each of `GT`, `EQ` and `LT` selecting its own string.

`classifyNumber` binds the result of `case compare n 0` and returns it; it is
called with 5, 0 and -3.

-}

-- CHECK: let1: "positive"
-- CHECK: let2: "zero"
-- CHECK: let3: "negative"

import Html exposing (text)


classifyNumber n =
    let
        sign = case compare n 0 of
            GT -> "positive"
            EQ -> "zero"
            LT -> "negative"
    in
    sign


main =
    let
        _ = Debug.log "let1" (classifyNumber 5)
        _ = Debug.log "let2" (classifyNumber 0)
        _ = Debug.log "let3" (classifyNumber -3)
    in
    text "done"

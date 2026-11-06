module CaseFanOutShadowTest exposing (main)

{-| A function that destructures a custom type in its parameter and then cases on a `Result` combines the bound field with the `Ok` value, or returns -1 for `Err`.
-}

-- CHECK: r1: 5
-- CHECK: r2: -1
-- CHECK: r3: 0

import Html exposing (text)


type Wrapper
    = Wrapper Int (List Int)


sumWrapper : Wrapper -> Int
sumWrapper (Wrapper head tail) =
    case tail of
        [] ->
            head

        first :: rest ->
            head + sumWrapper (Wrapper first rest)


safeDivide : Int -> Int -> Result String Int
safeDivide a b =
    if b == 0 then
        Err "division by zero"

    else
        Ok (a // b)


processWrapper : Wrapper -> Result String Int -> Int
processWrapper (Wrapper n _) result =
    case result of
        Ok value ->
            n + value

        Err _ ->
            -1


main =
    let
        w = Wrapper 3 [ 1, 2 ]
        _ = Debug.log "r1" (processWrapper w (safeDivide 4 2))
        _ = Debug.log "r2" (processWrapper w (Err "oops"))
        _ = Debug.log "r3" (processWrapper (Wrapper 0 []) (Ok 0))
    in
    text "done"

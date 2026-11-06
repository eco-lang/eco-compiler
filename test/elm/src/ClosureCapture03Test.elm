module ClosureCapture03Test exposing (main)

{-| A lambda returned from a function captures a value of a two-constructor custom
type, both of whose constructors carry a payload, and matches on it with `case`
when called.

The module defines its own `MyResult` with constructors `Ok` and `Err`. `Ok 42`
gives 42 and `Err "bad"` gives -1.

-}

-- CHECK: ok: 42
-- CHECK: err: -1

import Html exposing (text)


type MyResult a b
    = Ok a
    | Err b


resultToInt : MyResult Int String -> (Int -> Int)
resultToInt r =
    \dummy ->
        case r of
            Ok n ->
                n

            Err _ ->
                -1


main =
    let
        _ = Debug.log "ok" (resultToInt (Ok 42) 0)
        _ = Debug.log "err" (resultToInt (Err "bad") 0)
    in
    text "done"

module CustomTypeFuncFieldTest exposing (main)

{-| A custom type whose single constructor wraps a function can be unwrapped by
an argument pattern and the function called.

`runOp` applies the wrapped function to 10: with `\x -> x + 1` the result is
11, and with `\x -> x * 2` it is 20.

-}

-- CHECK: op1: 11
-- CHECK: op2: 20

import Html exposing (text)


type Op
    = Op (Int -> Int)


runOp : Op -> Int
runOp (Op f) =
    f 10


main =
    let
        _ =
            Debug.log "op1" (runOp (Op (\x -> x + 1)))

        _ =
            Debug.log "op2" (runOp (Op (\x -> x * 2)))
    in
    text "done"

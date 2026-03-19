module CustomTypeFuncFieldTest exposing (main)

{-| Test custom type wrapping a function field. -}

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

module NonZeroArityRecursionTest exposing (main)

{-| Negative control: ordinary recursive function (non-zero arity).

    `countDown : Int -> Int` is a function, not a value. Its "construction"
    is just installing the function symbol; the recursive call only happens
    at invocation time. This must always work.

    Expected: prints "countDown: 0" without crashing.
-}

-- CHECK: countDown: 0

import Html exposing (text)


countDown : Int -> Int
countDown n =
    if n <= 0 then
        0

    else
        countDown (n - 1)


main =
    let
        _ =
            Debug.log "countDown" (countDown 100)
    in
    text "done"
